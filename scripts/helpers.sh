#!/usr/bin/env bash
set -euo pipefail

# Helper functions for interacting with Rackspace Spot API
: "${SPOT_API_BASE:=https://spot.rackspace.com/api/v1}"
TOKEN_CACHE="${XDG_RUNTIME_DIR:-/tmp}/spot_token.json"

# Cost-effectiveness weights (tweakable via env vars)
: "${VCPU_WEIGHT:=1.0}"
: "${MEM_WEIGHT:=0.5}"
: "${GPU_WEIGHT:=4.0}"  # GPUs count heavily

log() { if [ "${DEBUG:-0}" -eq 1 ]; then printf "%s %s\n" "$(date -Is)" "$*" >&2; fi; }

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
  if [ -n "$data" ]; then
    resp=$(curl -s -w "\n%{http_code}" -X "$method" -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" "${url}" --data "$data")
    curl_exit=$?
  else
    resp=$(curl -s -w "\n%{http_code}" -X "$method" -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" "${url}")
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

  # Process and rank server classes
  local ranked_classes=""
  local count=$(echo "$resp" | jq '. | length')

  for ((i=0; i<count; i++)); do
    local item=$(echo "$resp" | jq ".[$i]")
    local code=$(echo "$item" | jq -r '.code')
    local vcpu=$(echo "$item" | jq -r '.vcpu')
    local memory_gb=$(echo "$item" | jq -r '.memoryGB')
    local price_hour=$(echo "$item" | jq -r '.price')

    # Extract GPU count
    local gpu_count=0
    local gpu_info=$(echo "$item" | jq -r '.gpu_info // .gpus // .gpu_count // .accelerators // empty')
    if [ -n "$gpu_info" ] && [ "$gpu_info" != "null" ]; then
      if [[ "$gpu_info" =~ ^[0-9]+$ ]]; then
        gpu_count="$gpu_info"
      else
        gpu_count=$(echo "$gpu_info" | grep -o '[0-9]\+' | head -1 || echo "0")
      fi
    fi

    # Adjust weights based on metric
    local vcpu_w="$VCPU_WEIGHT"
    local mem_w="$MEM_WEIGHT"
    local gpu_w="$GPU_WEIGHT"

    case "$metric" in
      "cpu-only")
        mem_w="0"
        gpu_w="0"
        ;;
      "cpu+mem")
        gpu_w="0"
        ;;
      "custom"|"cpu+mem+gpu")
        # Use default weights
        ;;
      *)
        log "WARNING: Unknown metric '$metric', using default cpu+mem+gpu"
        ;;
    esac

    # Calculate score
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

  return 0
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

  # Check if JSON is valid
  if ! echo "$json" | jq empty >/dev/null 2>&1; then
    log "ERROR: Invalid serverclass JSON response"
    return 1
  fi

  # Check for required fields in each serverclass
  local count=$(echo "$json" | jq '. | length')
  for ((i=0; i<count; i++)); do
    local item=$(echo "$json" | jq ".[$i]")
    local code=$(echo "$item" | jq -r '.code // empty')

    # Required fields per IMPROVMENTS.md
    local vcpu=$(echo "$item" | jq -r '.vcpu // empty')
    local memory_gb=$(echo "$item" | jq -r '.memoryGB // empty')
    local price_hour=$(echo "$item" | jq -r '.price // empty')

    if [ -z "$vcpu" ] || [ "$vcpu" = "null" ]; then
      missing_fields+=("$code: vcpu")
    fi
    if [ -z "$memory_gb" ] || [ "$memory_gb" = "null" ]; then
      missing_fields+=("$code: memoryGB")
    fi
    if [ -z "$price_hour" ] || [ "$price_hour" = "null" ]; then
      missing_fields+=("$code: price/hour")
    fi

    # Extract GPU count - try different field names that might contain GPU info
    local gpu_count=0
    local gpu_info=$(echo "$item" | jq -r '.gpu_info // .gpus // .gpu_count // .accelerators // empty')
    if [ -n "$gpu_info" ] && [ "$gpu_info" != "null" ]; then
      # If it's a number, use it directly
      if [[ "$gpu_info" =~ ^[0-9]+$ ]]; then
        gpu_count="$gpu_info"
      else
        # Try to extract number from string like "2x NVIDIA A100"
        gpu_count=$(echo "$gpu_info" | grep -o '[0-9]\+' | head -1 || echo "0")
      fi
    fi
    # Store gpu_count for later use
    jq -n --arg code "$code" --argjson gpu_count "$gpu_count" '{code: $code, gpu_count: $gpu_count}' >/dev/null 2>&1
  done

  if [ ${#missing_fields[@]} -gt 0 ]; then
    log "ERROR: Missing required fields in serverclass data: ${missing_fields[*]}"
    return 1
  fi

  return 0
}
}
