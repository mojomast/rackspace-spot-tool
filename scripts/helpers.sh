#!/usr/bin/env bash
set -euo pipefail

# Helper functions for interacting with Rackspace Spot API
: "${SPOT_API_BASE:=https://spot.rackspace.com/api/v1}"
TOKEN_CACHE="${XDG_RUNTIME_DIR:-/tmp}/spot_token.json"

# Cost-effectiveness weights (tweakable via env vars)
: "${VCPU_WEIGHT:=1.0}"
: "${MEM_WEIGHT:=0.5}"
: "${GPU_WEIGHT:=4.0}"  # GPUs count heavily

# Set default log level if not set
: "${LOG_LEVEL:=INFO}"

# Log levels: DEBUG=0, INFO=1, WARN=2, ERROR=3
get_log_level_num() {
    case "${LOG_LEVEL^^}" in
        DEBUG) echo 0 ;;
        INFO) echo 1 ;;
        WARN) echo 2 ;;
        ERROR) echo 3 ;;
        *) echo 1 ;;  # Default to INFO
    esac
}

log() {
    local level="${1:-INFO}"
    local message="$2"
    local level_num
    local current_level_num

    # If only one parameter, treat it as message and default level to INFO
    if [ $# -eq 1 ]; then
        message="$1"
        level="INFO"
    fi

    level_num=$(case "${level^^}" in
        DEBUG) echo 0 ;;
        INFO) echo 1 ;;
        WARN) echo 2 ;;
        ERROR) echo 3 ;;
        *) echo 1 ;;
    esac)

    current_level_num=$(get_log_level_num)

    if [ "$level_num" -ge "$current_level_num" ]; then
        printf "%s [%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$message" >&2
    fi
}

# get_spot_token: returns a bearer token (prints token)
get_spot_token() {
  if [ -n "${SPOT_API_TOKEN:-}" ]; then
    echo "${SPOT_API_TOKEN}"
    return 0
  fi

  # Try to reuse cached token if still valid
  if [ -f "${TOKEN_CACHE}" ]; then
    exp=$(jq -r '.expiry // empty' "${TOKEN_CACHE}" 2>/dev/null || echo "")
    token=$(jq -r '.token // empty' "${TOKEN_CACHE}" 2>/dev/null || echo "")
    if [ -n "$token" ] && [ -n "$exp" ]; then
      now=$(date +%s)
      if [ "$now" -lt "$exp" ]; then
        log "Using cached token (expires at $exp)"
        echo "$token"
        return 0
      fi
    fi
  fi

  if [ -n "${SPOT_CLIENT_ID:-}" ] && [ -n "${SPOT_CLIENT_SECRET:-}" ]; then
    log "Fetching token via client_credentials"
    resp=$(curl -s -w "\n%{http_code}" -X POST "${SPOT_API_BASE%/}/oauth/token"       -H "Content-Type: application/json"       -d "{"grant_type":"client_credentials","client_id":"${SPOT_CLIENT_ID}","client_secret":"${SPOT_CLIENT_SECRET}"}")
    curl_exit=$?
    http_code=$(echo "$resp" | tail -n1)
    body=$(echo "$resp" | sed '$d')

    if [ $curl_exit -eq 0 ] && [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
      :  # ok
    else
      local msg=$(echo "$body" | jq -r '.message // .error // .errors[0].message // "unknown"' 2>/dev/null || echo "unknown")
      echo "API error ${http_code}: $msg" >&2
      if [ "$DEBUG" = "1" ]; then
        echo "Full response: $body" >&2
      fi
      return 1
    fi

    token=$(echo "$body" | jq -r '.access_token // .id_token // empty')
    expires_in=$(echo "$body" | jq -r '.expires_in // 3600')
    if [ -z "$token" ]; then
      echo "Failed to obtain token from ${SPOT_API_BASE%/}/oauth/token" >&2
      return 1
    fi
    exp=$(( $(date +%s) + (expires_in - 30) ))
    jq -n --arg t "$token" --argjson e "$exp" '{token:$t, expiry:$e}' > "${TOKEN_CACHE}"
    echo "$token"
    return 0
  fi

  echo "ERROR: Must set SPOT_API_TOKEN or SPOT_CLIENT_ID+SPOT_CLIENT_SECRET" >&2
  return 1
}

# ensure_org_namespace: verifies the token has access to the namespace
ensure_org_namespace() {
  if [ -z "${SPOT_ORG_NAMESPACE:-}" ]; then
    echo "ERROR: SPOT_ORG_NAMESPACE is required" >&2
    return 1
  fi
  log "Verifying access to organization namespace: ${SPOT_ORG_NAMESPACE}"
  resp=$(api_call "GET" "/organizations") || return 1
  namespaces=$(echo "$resp" | jq -r '.[].name' 2>/dev/null || echo "")
  if ! echo "$namespaces" | grep -q "^${SPOT_ORG_NAMESPACE}$"; then
    log "ERROR: Token does not have access to namespace '${SPOT_ORG_NAMESPACE}'"
    log "Available namespaces: $namespaces"
    return 1
  fi
  log "Namespace access verified"
  return 0
}

# api_call <method> <path> [data]
# returns body and sets HTTP_STATUS global
# If path starts with /organizations/ and namespace is set, prepends namespace
api_call() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local token
  token=$(get_spot_token) || return 1
  local url="${SPOT_API_BASE%/}${path}"
  log "API CALL: ${method} ${url}"
  # Use connection reuse and reduce SSL overhead for better performance
  local curl_opts="-s -w '\n%{http_code}' --connect-timeout 10 --max-time 30"
  if [ -n "$data" ]; then
    resp=$(curl $curl_opts -X "$method" -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" "${url}" --data "$data")
    curl_exit=$?
  else
    resp=$(curl $curl_opts -X "$method" -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" "${url}")
    curl_exit=$?
  fi
  HTTP_STATUS=$(echo "$resp" | tail -n1)
  HTTP_BODY=$(echo "$resp" | sed '$d')
  if [ $curl_exit -ne 0 ] || [ "$HTTP_STATUS" -lt 200 ] || [ "$HTTP_STATUS" -ge 300 ]; then
    local msg=$(echo "$HTTP_BODY" | jq -r '.message // .error // .errors[0].message // "unknown"' 2>/dev/null || echo "unknown")
    echo "API error ${HTTP_STATUS}: $msg" >&2
    if [ "$DEBUG" = "1" ]; then
      echo "Full response: $HTTP_BODY" >&2
    fi
    return 1
  fi
  echo "$HTTP_BODY"
  return 0
# get_regions: fetch available regions from API
get_regions() {
  resp=$(api_call "GET" "/regions") || return 1
  echo "$resp" | jq -r '.[]?.code // empty' | grep -v '^$' || echo ""
  return 0
  }
  
  # validate_org_namespace: validate organization namespace format
  validate_org_namespace() {
    local ns="$1"
    if [ -z "$ns" ]; then
      log "ERROR: Organization namespace cannot be empty"
      return 1
    fi
    if [[ ! "$ns" =~ ^[a-zA-Z0-9_-]+$ ]]; then
      log "ERROR: Organization namespace contains invalid characters"
      return 1
    fi
    if [ ${#ns} -gt 64 ] || [ ${#ns} -lt 2 ]; then
      log "ERROR: Organization namespace length must be between 2 and 64 characters"
      return 1
    fi
    log "Organization namespace validated"
    return 0
  }
  
  # validate_node_count: validate node count is positive integer
  validate_node_count() {
    local count="$1"
    if [[ ! "$count" =~ ^[0-9]+$ ]] || [ "$count" -le 0 ]; then
      log "ERROR: Node count must be a positive integer"
      return 1
    fi
    if [ "$count" -gt 100 ]; then
      log "WARNING: Node count $count is very high, this may incur significant costs"
    fi
    log "Node count validated: $count"
    return 0
  }
  
  # validate_kubeconfig_path: validate kubeconfig file exists and is readable
  validate_kubeconfig_path() {
    local path="$1"
    if [ -z "$path" ]; then
      log "ERROR: Kubeconfig path cannot be empty"
      return 1
    fi
    if [ ! -f "$path" ]; then
      log "ERROR: Kubeconfig file does not exist: $path"
      return 1
    fi
    if [ ! -r "$path" ]; then
      log "ERROR: Kubeconfig file is not readable: $path"
      return 1
    fi
    log "Kubeconfig path validated: $path"
    return 0
  }
  
  # validate_namespace: validate Kubernetes namespace name
  validate_namespace() {
    local ns="$1"
    if [ -z "$ns" ]; then
      log "ERROR: Namespace cannot be empty"
      return 1
    fi
    if [[ ! "$ns" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
      log "ERROR: Invalid namespace format. Must be lowercase alphanumeric with optional dashes"
      return 1
    fi
    if [ ${#ns} -gt 63 ]; then
      log "ERROR: Namespace length exceeds 63 characters"
      return 1
    fi
    log "Namespace validated: $ns"
    return 0
  }
  
  # validate_password: basic password validation
  validate_password() {
    local password="$1"
    if [ -z "$password" ]; then
      log "ERROR: Password cannot be empty"
      return 1
    fi
    if [ ${#password} -lt 8 ]; then
      log "WARNING: Password is very short, consider using a stronger password"
    fi
    log "Password validated"
    return 0
  }
  
  # validate_storage_size: validate storage size format
  validate_storage_size() {
    local size="$1"
    if [[ ! "$size" =~ ^[0-9]+(Gi|Mi)$ ]]; then
      log "ERROR: Storage size must be in format [number](Gi|Mi), e.g., 10Gi"
      return 1
    fi
    local num=$(echo "$size" | sed 's/[A-Z]*$//')
    if [ "$num" -lt 1 ]; then
      log "ERROR: Storage size must be at least 1"
      return 1
    fi
    log "Storage size validated: $size"
    return 0
  }
  
  # validate_timezone: validate timezone format
  validate_timezone() {
    local tz="$1"
    if [ -z "$tz" ]; then
      log "ERROR: Timezone cannot be empty"
      return 1
    fi
    if ! echo "$tz" | grep -qE "^[A-Z][a-z_]+(/[A-Z][a-z_]+)?$"; then
      log "ERROR: Invalid timezone format, e.g., UTC, America/New_York"
      return 1
    fi
    log "Timezone validated: $tz"
    return 0
  }
  
  # validate_service_type: validate service type
  validate_service_type() {
    local type="$1"
    case "$type" in
      LoadBalancer|ClusterIP)
        log "Service type validated: $type"
        return 0
        ;;
      *)
        log "ERROR: Invalid service type. Must be LoadBalancer or ClusterIP"
        return 1
        ;;
    esac
  }

# get_serverclasses <region> [metric]: fetch and rank server classes for a region
# metric: optional, "cpu-only", "cpu+mem", or "custom" (default cpu+mem+gpu)
get_serverclasses() {
  local region="$1"
  local metric="${2:-cpu+mem+gpu}"
  if [ -z "$region" ]; then
    echo "ERROR: region required for serverclasses" >&2
    return 1
  fi

  local resp
  resp=$(api_call "GET" "/serverclasses?region=${region}") || return 1
  validate_serverclass_fields "$resp" || return 1

  process_and_rank_serverclasses "$resp" "$metric"
}

# Extract GPU count from serverclass item
extract_gpu_count() {
  local gpu_info="$1"
  local gpu_count=0
  if [ -n "$gpu_info" ] && [ "$gpu_info" != "null" ]; then
    if [[ "$gpu_info" =~ ^[0-9]+$ ]]; then
      gpu_count="$gpu_info"
    else
      gpu_count=$(echo "$gpu_info" | grep -o '[0-9]\+' | head -1 || echo "0")
    fi
  fi
  echo "$gpu_count"
}

# Adjust weights based on metric
adjust_weights_for_metric() {
  local metric="$1"
  local vcpu_w="$VCPU_WEIGHT"
  local mem_w="$MEM_WEIGHT"
  local gpu_w="$GPU_WEIGHT"

  case "$metric" in
    cpu-only)
      mem_w="0"
      gpu_w="0"
      ;;
    cpu+mem)
      gpu_w="0"
      ;;
    custom|cpu+mem+gpu)
      # Use default weights
      ;;
    *)
      log "WARNING: Unknown metric '$metric', using default cpu+mem+gpu"
      ;;
  esac

  echo "$vcpu_w $mem_w $gpu_w"
}

# Process and rank server classes
process_and_rank_serverclasses() {
  local resp="$1"
  local metric="$2"
  local ranked_classes=""
  local count=$(echo "$resp" | jq '. | length')

  for ((i=0; i<count; i++)); do
    local item=$(echo "$resp" | jq ".[$i]")
    local code=$(echo "$item" | jq -r '.code')
    local vcpu=$(echo "$item" | jq -r '.vcpu')
    local memory_gb=$(echo "$item" | jq -r '.memoryGB')
    local price_hour=$(echo "$item" | jq -r '.price')
    local gpu_info=$(echo "$item" | jq -r '.gpu_info // .gpus // .gpu_count // .accelerators // empty')
    local gpu_count=$(extract_gpu_count "$gpu_info")
    local weights=$(adjust_weights_for_metric "$metric")
    local vcpu_w=$(echo "$weights" | cut -d' ' -f1)
    local mem_w=$(echo "$weights" | cut -d' ' -f2)
    local gpu_w=$(echo "$weights" | cut -d' ' -f3)

    local denominator=$(echo "scale=6; $vcpu_w * $vcpu + $mem_w * $memory_gb + $gpu_w * $gpu_count" | bc -l 2>/dev/null)
    if [ -z "$denominator" ] || [ "$(echo "$denominator <= 0" | bc -l)" = "1" ]; then
      log "WARNING: Invalid denominator for $code, skipping"
      continue
    fi

    local score=$(echo "scale=6; $price_hour / $denominator" | bc -l 2>/dev/null)
    if [ -z "$score" ]; then
      log "WARNING: Could not calculate score for $code"
      continue
    fi

    # Store with score for sorting
    ranked_classes="${ranked_classes}${score}|${code}\n"
  done

  # Sort by score (ascending - lower score is better) and extract codes
  if [ -n "$ranked_classes" ]; then
    echo -e "$ranked_classes" | sort -n | cut -d'|' -f2
  else
    log "WARNING: No valid server classes found"
    echo ""
  fi
}

# calculate_serverclass_score: compute cost-effectiveness score
# Formula: score = price_per_hour / (vcpu_weight * vCPUs + mem_weight * memory_gb + gpu_weight * gpu_score)
# Returns score or empty string if calculation fails
calculate_serverclass_score() {
  local vcpu="$1"
  local memory_gb="$2"
  local price_hour="$3"
  local gpu_count="${4:-0}"

  # Convert to numbers, use bc for floating point arithmetic
  local score
  score=$(echo "scale=6; $price_hour / ($VCPU_WEIGHT * $vcpu + $MEM_WEIGHT * $memory_gb + $GPU_WEIGHT * $gpu_count)" | bc -l 2>/dev/null || echo "")

  if [ -z "$score" ] || [ "$score" = "0" ]; then
    echo ""
  else
    echo "$score"
  fi
}

# validate_serverclass_fields: check required fields exist in serverclass data
validate_serverclass_fields() {
  local json="$1"
  local missing_fields=()

  if ! echo "$json" | jq empty >/dev/null 2>&1; then
    log "ERROR: Invalid serverclass JSON response"
    return 1
  fi

  local count=$(echo "$json" | jq '. | length')
  for ((i=0; i<count; i++)); do
    local item=$(echo "$json" | jq ".[$i]")
    local code=$(echo "$item" | jq -r '.code // empty')
    local vcpu=$(echo "$item" | jq -r '.vcpu // empty')
    local memory_gb=$(echo "$item" | jq -r '.memoryGB // empty')
    local price_hour=$(echo "$item" | jq -r '.price // empty')

    check_required_fields "$code" "$vcpu" "$memory_gb" "$price_hour" missing_fields
    extract_and_store_gpu_count "$item"
  done

  if [ ${#missing_fields[@]} -gt 0 ]; then
    log "ERROR: Missing required fields in serverclass data: ${missing_fields[*]}"
    return 1
  fi

  return 0
}

# Check required fields for a serverclass
check_required_fields() {
  local code="$1"
  local vcpu="$2"
  local memory_gb="$3"
  local price_hour="$4"
  local -n missing_fields_ref=$5

  if [ -z "$vcpu" ] || [ "$vcpu" = "null" ]; then
    missing_fields_ref+=("$code: vcpu")
  fi
  if [ -z "$memory_gb" ] || [ "$memory_gb" = "null" ]; then
    missing_fields_ref+=("$code: memoryGB")
  fi
  if [ -z "$price_hour" ] || [ "$price_hour" = "null" ]; then
    missing_fields_ref+=("$code: price/hour")
  fi
}

# Extract GPU count for later use
extract_and_store_gpu_count() {
  local item="$1"
  local gpu_info=$(echo "$item" | jq -r '.gpu_info // .gpus // .gpu_count // .accelerators // empty')
  local gpu_count=$(extract_gpu_count "$gpu_info")
  # Store gpu_count for later use
  jq -n --arg code "$(echo "$item" | jq -r '.code')" --argjson gpu_count "$gpu_count" '{code: $code, gpu_count: $gpu_count}' >/dev/null 2>&1
}

# Extract GPU count from serverclass item
extract_gpu_count() {
  local gpu_info="$1"
  local gpu_count=0
  if [ -n "$gpu_info" ] && [ "$gpu_info" != "null" ]; then
    if [[ "$gpu_info" =~ ^[0-9]+$ ]]; then
      gpu_count="$gpu_info"
    else
      gpu_count=$(echo "$gpu_info" | grep -o '[0-9]\+' | head -1 || echo "0")
    fi
  fi
  echo "$gpu_count"
}
}
