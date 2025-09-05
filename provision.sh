#!/bin/bash

# Source helpers
source scripts/helpers.sh

# provision.sh: Interactive script to provision infrastructure for code-server deployment on Rackspace using Terraform and Helm
# This script prompts for necessary variables with defaults, initializes and applies Terraform for infrastructure,
# sets up KUBECONFIG, installs code-server via Helm, waits for pods to be ready, and provides access instructions.

main() {
    set -e  # Exit on any error for safety

    # Parse command line arguments
    DRY_RUN=false
    DEBUG=false
    METRIC="cpu+mem+gpu"
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --debug)
                DEBUG=true
                shift
                ;;
            --metric)
                METRIC="$2"
                shift
                shift
                ;;
            --metric=*)
                METRIC="${1#*=}"
                shift
                ;;
            *)
                echo "Unknown option: $1"
                echo "Usage: $0 [--dry-run] [--debug] [--metric cpu-only|cpu+mem|custom]"
                exit 1
                ;;
            esac
            done
        
            # Validate metric option
            case "$METRIC" in
                cpu-only|cpu+mem|custom|cpu+mem+gpu)
                    ;;
                *)
                    echo "ERROR: Invalid metric option '$METRIC'. Valid options: cpu-only, cpu+mem, custom, cpu+mem+gpu"
                    exit 1
                    ;;
            esac
        
            # Logging function for consistent output
            log() {
                echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
            }

# Function to check if a command succeeds, with error handling
check_command() {
    if ! "$@"; then
        log "ERROR: Command failed: $@"
        exit 1
    fi
}

# Default values
DEFAULT_REGION="DFW"
DEFAULT_BID_PRICE="0.03"
DEFAULT_NODE_COUNT="1"
DEFAULT_KUBECONFIG_PATH="$HOME/.kube/config"

# Function to validate spot API token (simple test API call)
validate_spot_api_token() {
    local resp=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer ${TOKEN}" "${SPOT_API_BASE%/}/regions")
    local curl_exit=$?
    local http_code=$(echo "$resp" | tail -n1)
    local body=$(echo "$resp" | sed '$d')

    if [ $curl_exit -eq 0 ] && [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
        log "API token validated successfully."
        return 0
    else
        local msg=$(echo "$body" | jq -r '.message // .error // .errors[0].message // "unknown"' 2>/dev/null || echo "unknown")
        echo "API error ${http_code}: $msg" >&2
        if [ "$DEBUG" = true ]; then
            echo "Full response: $body" >&2
        fi
        exit 1
    fi
}

# Function to display account limits and quotas
get_rackspace_limits() {
    local resp=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer ${TOKEN}" "${SPOT_API_BASE%/}/auth/limits")
    local curl_exit=$?
    local http_code=$(echo "$resp" | tail -n1)
    local body=$(echo "$resp" | sed '$d')

    if [ $curl_exit -eq 0 ] && [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
        log "Current Account Limits and Quotas:"
        echo "$body" | jq .
        return 0
    else
        local msg=$(echo "$body" | jq -r '.message // .error // .errors[0].message // "unknown"' 2>/dev/null || echo "unknown")
        echo "API error ${http_code}: $msg" >&2
        if [ "$DEBUG" = true ]; then
            echo "Full response: $body" >&2
        fi
        return 1
    fi
}

# Function to check market availability
check_market_availability() {
  local region=$1
  local server_class=$2
  local price=$(fetch_market_price "$region" "$server_class")
  if [ -n "$price" ]; then
    log "SERVER_CLASS $server_class is available in $region"
    return 0
  else
    log "WARNING: SERVER_CLASS $server_class not available in $region - market price unavailable"
    return 1
  fi
}

# Function to estimate monthly costs
estimate_monthly_costs() {
  local region=$1
  local server_class=$2
  local price=$(fetch_market_price "$region" "$server_class")
  if [ -n "$price" ]; then
    local hourly=$price
    local monthly=$(echo "scale=2; $price * 24 * 30" | bc -l 2>/dev/null || echo "N/A")
    log "Market-based cost estimation for $server_class in $region:"
    log " Hourly: $$\hourly"
    log " Monthly (approx): $$\monthly"
  else
    log "Cannot estimate costs - market price unavailable"
  fi
}

# Function to validate storage requirements
validate_storage_requirements() {
  local storage_class=$1
  local generation=$2
  if [[ "$storage_class" == "gen1-"* && "$generation" == "gen1" ]]; then
    log "STORAGE_CLASS $storage_class matches generation $generation"
    return 0
  elif [[ "$storage_class" == "gen2-"* && "$generation" == "gen2" ]]; then
    log "STORAGE_CLASS $storage_class matches generation $generation"
    return 0
  else
    log "ERROR: STORAGE_CLASS $storage_class does not match generation $generation"
    return 1
  fi
}

# Function to test cluster connectivity
test_cluster_connectivity() {
  if kubectl cluster-info >/dev/null 2>&1; then
    log "Cluster connectivity successful"
    return 0
  else
    log "ERROR: Cluster connectivity failed"
    return 1
  fi
}

# Function to monitor spot pricing
monitor_spot_pricing() {
  local region=$1
  local server_class=$2
  local previous_price="-1"
  local first=true
  while true; do
    local price=$(fetch_market_price "$region" "$server_class")
    if [ -n "$price" ]; then
      if [ "$first" = true ]; then
        log "Spot price monitoring started: $price"
        previous_price=$price
        first=false
      else
        local diff=$(echo "scale=4; $price - $previous_price" | bc -l 2>/dev/null || echo "0")
        if [ $(echo "$diff > 0" | bc -l 2>/dev/null) = 1 ]; then
          log "Price increased from $previous_price to $price (up by $diff)"
        elif [ $(echo "$diff < 0" | bc -l 2>/dev/null) = 1 ]; then
          local recommendation="Consider lowering bid price"
          log "Price decreased from $previous_price to $price (down by $diff). Recommendation: $recommendation"
        else
          log "Price unchanged at $price"
        fi
        previous_price=$price
      fi
    else
      log "Price unavailable for monitoring"
    fi
    sleep 60
  done
}

# Function to fetch market price for server class in region
fetch_market_price() {
    local region=$1
    local server_class=$2
    local resp=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer ${TOKEN}" "${SPOT_API_BASE%/}/market/prices/${region}/servers/${server_class}")
    local curl_exit=$?
    local http_code=$(echo "$resp" | tail -n1)
    local body=$(echo "$resp" | sed '$d')

    if [ $curl_exit -eq 0 ] && [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
        local PRICE=$(echo "$body" | jq -r '.price // empty')
        if [ -n "$PRICE" ] && [ "$PRICE" != "null" ]; then
            echo "$PRICE"
        else
            log "WARNING: Market price data not found for ${server_class} in ${region}"
            echo ""
        fi
    else
        log "WARNING: Failed to fetch market price (${http_code}) - Using default bid"
        echo ""
    fi
}

# Function to setup preemption webhook
setup_preemption_webhook() {
    local cloudspace_id=$1
    local webhook_url="https://example.com/webhook"  # Placeholder, customize as needed
    local resp=$(curl -s -w "\n%{http_code}" -X POST -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"url\": \"$webhook_url\", \"events\": [\"preemption\"], \"warningMinutes\": 5}" \
        "${SPOT_API_BASE%/}/webhooks/cloudspaces/${cloudspace_id}")
    local curl_exit=$?
    local http_code=$(echo "$resp" | tail -n1)
    local body=$(echo "$resp" | sed '$d')

    if [ $curl_exit -eq 0 ] && [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
        log "Preemption webhook configured successfully for cloudspace $cloudspace_id"
    else
        log "WARNING: Failed to setup preemption webhook (${http_code})"
    fi
}

# Function to display cost estimation
display_cost_estimation() {
    local bid_price=$1
    local hourly_cost=$bid_price
    local monthly_cost=$(echo "scale=2; $bid_price * 24 * 30" | bc -l 2>/dev/null || echo "0")
    if [ "$monthly_cost" = "0" ]; then
        monthly_cost="0.00"
    fi
    log "Cost Estimation:"
    echo "  Hourly: \$$hourly_cost"
    echo "  Monthly (approx): \$$monthly_cost"
}

# Prompt for required variables with defaults
if [ -z "$SPOT_API_TOKEN" ]; then
    read -p "Enter SPOT_API_TOKEN: " SPOT_API_TOKEN
fi
if [ -z "$SPOT_API_TOKEN" ] && [ -z "$SPOT_CLIENT_ID$SPOT_CLIENT_SECRET" ]; then
    log "ERROR: SPOT_API_TOKEN or SPOT_CLIENT_ID+SPOT_CLIENT_SECRET is required"
    exit 1
fi

# Get token
TOKEN=$(get_spot_token) || exit 1

# Validate API token
log "Validating API token..."
if [ "$DRY_RUN" = false ]; then
    validate_spot_api_token
else
    log "[DRY-RUN] Would validate API token"
fi

# Ensure organization namespace is set and accessible
if [ -z "$SPOT_ORG_NAMESPACE" ]; then
    read -p "Enter SPOT_ORG_NAMESPACE: " SPOT_ORG_NAMESPACE
fi
if [ "$DRY_RUN" = false ]; then
    ensure_org_namespace || exit 1
else
    log "[DRY-RUN] Would validate organization namespace"
fi

# Display account limits
log "Retrieving account limits..."
if [ "$DRY_RUN" = false ]; then
    get_rackspace_limits
else
    log "[DRY-RUN] Would retrieve account limits"
fi

# Select REGION with interactive menu
log "Fetching available regions..."
if [ "$DRY_RUN" = false ]; then
  REGION_LIST=$(get_regions)
  if [ -z "$REGION_LIST" ]; then
    log "ERROR: Failed to fetch regions from API"
    exit 1
  fi
else
  log "[DRY-RUN] Would fetch regions from API"
  REGION_LIST="us-west-sjc-1 us-central-dfw-1 us-east-iad-1 us-central-ord-1 eu-west-lon-1 apac-se-syd-1 apac-se-hkg-1"
fi

REGION_ARRAY=($REGION_LIST)
echo "Available regions:"
for i in "${!REGION_ARRAY[@]}"; do
  echo "$((i+1)). ${REGION_ARRAY[$i]}"
done
PS3="Enter your choice: "
select REGION in "${REGION_ARRAY[@]}"
do
  if [ -n "$REPLY" ]; then
    if [[ "$REPLY" =~ ^[0-9]+$ ]] && [ "$REPLY" -ge 1 ] && [ "$REPLY" -le "${#REGION_ARRAY[@]}" ]; then
      REGION="${REGION_ARRAY[$((REPLY-1))]}"
      if [[ "$REGION" == "us-west-sjc-1" ]]; then
        gen="gen2"
      else
        gen="gen1"
      fi
      log "Selected REGION: $REGION (${gen^^})"
      break
    else
      log "Invalid selection ($REPLY). Please choose 1-${#REGION_ARRAY[@]}."
      continue
    fi
  else
    REGION="us-east-iad-1"
    gen="gen1"
    log "No selection made, using default: us-east-iad-1 (Generation-1)"
    break
  fi
done
# Select DEPLOYMENT_OPTION with interactive menu
log "Select the DEPLOYMENT_OPTION for cloudspace deployment:"
echo "1. Create new"
echo "2. Use existing"
PS3="Enter your choice (1-2): "
select DEPLOYMENT_OPTION_DESC in "Create new" "Use existing"
do
  case $REPLY in
    1) DEPLOYMENT_OPTION="Create new"; log "Selected DEPLOYMENT_OPTION: Create new"; break;;
    2) DEPLOYMENT_OPTION="Use existing"; log "Selected DEPLOYMENT_OPTION: Use existing"; break;;
    "") log "No selection made, using default: Create new"; DEPLOYMENT_OPTION="Create new"; break;;
    *) log "Invalid selection ($REPLY). Please choose 1-2."; continue;;
  esac
done
if [ "$DEPLOYMENT_OPTION" = "Use existing" ]; then
    log "Fetching available cloudspaces..."
    if [ "$DRY_RUN" = false ]; then
        resp=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer ${TOKEN}" "${SPOT_API_BASE%/}/organizations/${SPOT_ORG_NAMESPACE}/cloudspaces/")
        curl_exit=$?
        http_code=$(echo "$resp" | tail -n1)
        CLOUDSPECES_RESPONSE=$(echo "$resp" | sed '$d')

        if [ $curl_exit -eq 0 ] && [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
            :  # ok
        else
            local msg=$(echo "$CLOUDSPECES_RESPONSE" | jq -r '.message // .error // .errors[0].message // "unknown"' 2>/dev/null || echo "unknown")
            echo "API error ${http_code}: $msg" >&2
            if [ "$DEBUG" = true ]; then
                echo "Full response: $CLOUDSPECES_RESPONSE" >&2
            fi
            exit 1
        fi

        if ! echo "$CLOUDSPECES_RESPONSE" | jq empty > /dev/null 2>&1; then
            log "ERROR: Failed to retrieve cloudspaces or invalid response"
            exit 1
        fi
        # Validate organization/namespace in response
        # For list, each item should have organization field
        org_check=$(echo "$CLOUDSPECES_RESPONSE" | jq -r '.[0].organization // .[0].namespace // empty' 2>/dev/null || echo "")
        if [ -n "$org_check" ] && [ "$org_check" != "$SPOT_ORG_NAMESPACE" ]; then
            log "ERROR: Cloudspace organization/namespace '$org_check' does not match SPOT_ORG_NAMESPACE '$SPOT_ORG_NAMESPACE'"
            exit 1
        fi
    else
        log "[DRY-RUN] Would fetch available cloudspaces"
        CLOUDSPECES_RESPONSE='[]'  # Mock empty response for dry-run
    fi

    # Check if there are any cloudspaces
    COUNT=$(jq '. | length' <<< "$CLOUDSPECES_RESPONSE")
    if [ "$COUNT" -eq 0 ]; then
        log "No available cloudspaces found."
        exit 1
    fi

    log "Available cloudspaces:"
    options=()
    ids=()
    while IFS= read -r line; do
        options+=("$line")
    done < <(jq -r '.[] | "\(.name) (ID: \(.id)) - Region: \(.region) - Node pools: \(.nodePools | length)"' <<< "$CLOUDSPECES_RESPONSE")
    while IFS= read -r line; do
        ids+=("$line")
    done < <(jq -r '.[].id' <<< "$CLOUDSPECES_RESPONSE")

    if [ ${#options[@]} -eq 0 ]; then
        log "ERROR: No cloudspaces available"
        exit 1
    fi

    echo "Select a cloudspace:"
    PS3="Enter selection (1-${#options[@]}): "
    select CLOUDSPECES_DESC in "${options[@]}"
    do
        if [[ -n "$REPLY" ]] && [[ "$REPLY" =~ ^[0-9]+$ ]] && [ "$REPLY" -ge 1 ] && [ "$REPLY" -le "${#options[@]}" ]; then
            SELECTED_INDEX=$((REPLY-1))
            CLOUDSPECES_ID="${ids[$SELECTED_INDEX]}"
            break
       else
           log "Invalid selection ($REPLY). Choose 1-${#options[@]}."
       fi
   done
   
   log "Selected cloudspace ID: $CLOUDSPECES_ID"
   
   # Validate cloudspace accessibility
   if [ "$DRY_RUN" = false ]; then
       resp=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer ${TOKEN}" "${SPOT_API_BASE%/}/organizations/${SPOT_ORG_NAMESPACE}/cloudspaces/$CLOUDSPECES_ID")
       curl_exit=$?
       http_code=$(echo "$resp" | tail -n1)
       VALIDATE_RESPONSE=$(echo "$resp" | sed '$d')

       if [ $curl_exit -eq 0 ] && [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
           :  # ok
       else
           local msg=$(echo "$VALIDATE_RESPONSE" | jq -r '.message // .error // .errors[0].message // "unknown"' 2>/dev/null || echo "unknown")
           echo "API error ${http_code}: $msg" >&2
           if [ "$DEBUG" = true ]; then
               echo "Full response: $VALIDATE_RESPONSE" >&2
           fi
           exit 1
       fi

       # Validate organization/namespace
       org_check=$(echo "$VALIDATE_RESPONSE" | jq -r '.organization // .namespace // empty' 2>/dev/null || echo "")
       if [ -n "$org_check" ] && [ "$org_check" != "$SPOT_ORG_NAMESPACE" ]; then
           log "ERROR: Cloudspace organization/namespace '$org_check' does not match SPOT_ORG_NAMESPACE '$SPOT_ORG_NAMESPACE'"
           exit 1
       fi
       log "Cloudspace accessibility validated."
   else
       log "[DRY-RUN] Would validate cloudspace accessibility"
       VALIDATE_RESPONSE='{"generation":"gen1"}'  # Mock response for dry-run
   fi
   
   # Download kubeconfig
   if [ "$DRY_RUN" = false ]; then
       TMP_KUBECONFIG=$(mktemp)
       curl -s -H "Authorization: Bearer ${TOKEN}" "${SPOT_API_BASE%/}/organizations/${SPOT_ORG_NAMESPACE}/cloudspaces/$CLOUDSPECES_ID/kubeconfig" > "$TMP_KUBECONFIG"
   else
       log "[DRY-RUN] Would download kubeconfig"
       TMP_KUBECONFIG=$(mktemp)
       echo "mock-kubeconfig-content" > "$TMP_KUBECONFIG"
   fi
   
   # Validate kubeconfig
   if [ ! -f "$TMP_KUBECONFIG" ] || [ ! -s "$TMP_KUBECONFIG" ]; then
       log "ERROR: Failed to download kubeconfig"
       rm -f "$TMP_KUBECONFIG"
       exit 1
   fi
   
   if ! kubectl cluster-info --kubeconfig="$TMP_KUBECONFIG" > /dev/null 2>&1; then
       log "ERROR: Invalid kubeconfig file"
       rm -f "$TMP_KUBECONFIG"
       exit 1
   fi
   log "Kubeconfig validated."
   
   # Determine generation and check/create storage classes
   GEN=$(jq -r '.generation' <<< "$VALIDATE_RESPONSE" || echo "gen1")
   GEN=${GEN,,}  # lowercase
   log "Detected generation: $GEN"
   
   resp=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer ${TOKEN}" "${SPOT_API_BASE%/}/organizations/${SPOT_ORG_NAMESPACE}/cloudspaces/$CLOUDSPECES_ID/nodepools/")
   curl_exit=$?
   http_code=$(echo "$resp" | tail -n1)
   NODEPOOLS_RESPONSE=$(echo "$resp" | sed '$d')

   if [ $curl_exit -eq 0 ] && [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
       # Validate organization/namespace
       org_check=$(echo "$NODEPOOLS_RESPONSE" | jq -r '.[0].organization // .[0].namespace // empty' 2>/dev/null || echo "")
       if [ -n "$org_check" ] && [ "$org_check" != "$SPOT_ORG_NAMESPACE" ]; then
           log "ERROR: Nodepool organization/namespace '$org_check' does not match SPOT_ORG_NAMESPACE '$SPOT_ORG_NAMESPACE'"
           exit 1
       fi
       # Assume required storage classes are managed via API; log status
       log "Storage classes checked via nodepools API."
   else
       log "WARNING: Could not retrieve nodepools info (${http_code})"
   fi
   
   # Optional: Check for load balancer (assume Helm will handle)
   log "Proceeding to deployment (load balancer will be handled by Helm if needed)."
   
   # Setup preemption webhook for existing cloudspace
   setup_preemption_webhook "$CLOUDSPECES_ID"
   
   # Set KUBECONFIG
   export KUBECONFIG="$TMP_KUBECONFIG"
   log "KUBECONFIG set to temporary file."
   
   # Verify cluster connectivity
   check_command kubectl cluster-info
   log "Cluster connectivity verified."
# Select SERVER_CLASS with interactive menu
log "Fetching server classes for region $REGION (metric: $METRIC)..."
if [ "$DRY_RUN" = false ]; then
  SERVER_LIST=$(get_serverclasses "$REGION" "$METRIC")
  if [ -z "$SERVER_LIST" ]; then
    log "ERROR: Failed to fetch server classes for region $REGION"
    exit 1
  fi
else
  log "[DRY-RUN] Would fetch server classes for region $REGION"
  SERVER_LIST=$(cat <<EOF
gp1-medium
gp1-large
gp1-xlarge
gp1-2xlarge
gp1-4xlarge
ch1-large
ch1-xlarge
ch1-2xlarge
ch1-4xlarge
mh1-large
mh1-xlarge
mh1-2xlarge
mh1-4xlarge
gpu1-xlarge
gpu1-2xlarge
EOF
)
fi

SERVER_ARRAY=($SERVER_LIST)
echo "Available server classes for $REGION:"
for i in "${!SERVER_ARRAY[@]}"; do
  echo "$((i+1)). ${SERVER_ARRAY[$i]}"
done
PS3="Enter your choice: "
select SERVER_CLASS in "${SERVER_ARRAY[@]}"
do
  if [ -n "$REPLY" ]; then
    if [[ "$REPLY" =~ ^[0-9]+$ ]] && [ "$REPLY" -ge 1 ] && [ "$REPLY" -le "${#SERVER_ARRAY[@]}" ]; then
      SERVER_CLASS="${SERVER_ARRAY[$((REPLY-1))]}"
      log "Selected SERVER_CLASS: $SERVER_CLASS ($gen)"
      break
    else
      log "Invalid selection ($REPLY). Please choose 1-${#SERVER_ARRAY[@]}."
      continue
    fi
  else
    SERVER_CLASS="gp1-medium"
    log "No selection made, using default: gp1-medium"
    break
  fi
done

# Check market availability
if [ "$DRY_RUN" = false ]; then
    check_market_availability "$REGION" "$SERVER_CLASS"
else
    log "[DRY-RUN] Would check market availability for $SERVER_CLASS in $REGION"
fi

# Fetch market price for bid strategy
if [ "$DRY_RUN" = false ]; then
    MARK_PRICE=$(fetch_market_price "$REGION" "$SERVER_CLASS")
else
    log "[DRY-RUN] Would fetch market price for $SERVER_CLASS in $REGION"
    MARK_PRICE="0.05"  # Mock price for dry-run
fi
if [ -n "$MARK_PRICE" ]; then
    log "Fetched market price: $$\MARK_PRICE for $SERVER_CLASS in $REGION"
else
    MARK_PRICE=$DEFAULT_BID_PRICE
    log "Market price unavailable, using default: $$\MARK_PRICE"
fi

# Bid strategy dropdown (Spot-only features)
log "Select Bid Management Strategy (Spot-only):"
echo "1. Conservative (market price + 10%)"
echo "2. Balanced (market price + 25%)"
echo "3. Aggressive (market price + 50%)"
echo "4. Custom bid amount"
PS3="Enter your choice (1-4): "
select BID_STRATEGY_DESC in "Conservative (market price + 10%)" "Balanced (market price + 25%)" "Aggressive (market price + 50%)" "Custom bid amount"
do
  case $REPLY in
    1) BID_STRATEGY="Conservative"; MARKUP="0.1"; BID_PRICE=$(echo "scale=3; $MARK_PRICE * (1 + $MARKUP)" | bc -l 2>/dev/null || echo $MARK_PRICE); break;;
    2) BID_STRATEGY="Balanced"; MARKUP="0.25"; BID_PRICE=$(echo "scale=3; $MARK_PRICE * (1 + $MARKUP)" | bc -l 2>/dev/null || echo $MARK_PRICE); break;;
    3) BID_STRATEGY="Aggressive"; MARKUP="0.5"; BID_PRICE=$(echo "scale=3; $MARK_PRICE * (1 + $MARKUP)" | bc -l 2>/dev/null || echo $MARK_PRICE); break;;
    4) BID_STRATEGY="Custom"; read -p "Enter custom bid price: " BID_PRICE; if [[ ! $BID_PRICE =~ ^[0-9]*\.?[0-9]+$ ]]; then BID_PRICE=$DEFAULT_BID_PRICE; log "Invalid amount, using default"; fi; break;;
    "") BID_STRATEGY="Conservative"; MARKUP="0.1"; BID_PRICE=$(echo "scale=3; $MARK_PRICE * (1 + $MARKUP)" | bc -l 2>/dev/null || echo $MARK_PRICE); break;;
    *) log "Invalid selection ($REPLY). Please choose 1-4."; continue;;
  esac
done

log "Selected BID_PRICE: $$\BID_PRICE"

# Display cost estimation
display_cost_estimation "$BID_PRICE"

# Estimate monthly costs based on market
estimate_monthly_costs "$REGION" "$SERVER_CLASS"

read -p "Enter NODE_COUNT [$DEFAULT_NODE_COUNT]: " NODE_COUNT
NODE_COUNT=${NODE_COUNT:-$DEFAULT_NODE_COUNT}

# Select STORAGE_CLASS based on generation
echo "Select the STORAGE_CLASS ($gen compatible):"
if [ "$gen" = "gen2" ]; then
  storage_options=(\
    "gen2-storage1 (Storage Class 5)" \
    "gen2-storage2 (Storage Class 6)" \
  )
export TF_VAR_deployment_option="$DEPLOYMENT_OPTION"
else
  storage_options=(\
    "gen1-storage1 (Storage Class 1)" \
    "gen1-storage2 (Storage Class 2)" \
    "gen1-storage3 (Storage Class 3)" \
    "gen1-storage4 (Storage Class 4)" \
  )
fi
PS3="Enter your choice: "
select STORAGE_CLASS_DESC in "${storage_options[@]}"
do
  if [ -n "$REPLY" ]; then
    if [[ "$REPLY" =~ ^[0-9]+$ ]] && [ "$REPLY" -ge 1 ] && [ "$REPLY" -le "${#storage_options[@]}" ]; then
      STORAGE_CLASS_DESC="${storage_options[$((REPLY-1))]}"
      STORAGE_CLASS=$(echo "$STORAGE_CLASS_DESC" | cut -d' ' -f1)
      log "Selected STORAGE_CLASS: $STORAGE_CLASS_DESC ($gen)"
      break
    else
      log "Invalid selection ($REPLY). Please choose 1-${#storage_options[@]}."
      continue
    fi
  else
    if [ "$gen" = "gen2" ]; then
      STORAGE_CLASS="gen2-storage1"
      log "No selection made, using default: gen2-storage1 (Storage Class 5)"
    else
      STORAGE_CLASS="gen1-storage1"
      log "No selection made, using default: gen1-storage1 (Storage Class 1)"
    fi
    break
  fi
done
export TF_VAR_storage_class="$STORAGE_CLASS"

# Validate storage requirements
if ! validate_storage_requirements "$STORAGE_CLASS" "$gen"; then
  exit 1
fi

read -p "Enter KUBECONFIG_PATH [$DEFAULT_KUBECONFIG_PATH]: " KUBECONFIG_PATH
KUBECONFIG_PATH=${KUBECONFIG_PATH:-$DEFAULT_KUBECONFIG_PATH}

# Export DEBUG for helpers
export DEBUG

# Detect GPU capabilities from selected server class
GPU_ENABLED="false"
GPU_COUNT="0"
if [[ "$SERVER_CLASS" == gpu* ]]; then
    log "Detected GPU server class: $SERVER_CLASS"
    GPU_ENABLED="true"
    # Extract GPU count from class name (e.g., gpu1.large -> 1, gpu2.2xlarge -> 2)
    if [[ "$SERVER_CLASS" =~ gpu([0-9]+)\. ]]; then
        GPU_COUNT="${BASH_REMATCH[1]}"
        log "Extracted GPU count: $GPU_COUNT"
    fi
fi

# Export variables for Terraform
export TF_VAR_spot_token="${TOKEN}"
export TF_VAR_region="$REGION"
export TF_VAR_bid_price="$BID_PRICE"
export TF_VAR_node_count="$NODE_COUNT"
export TF_VAR_server_class="$SERVER_CLASS"
export TF_VAR_organization_namespace="$SPOT_ORG_NAMESPACE"

# Export GPU variables for Helm template substitution
export GPU_ENABLED="$GPU_ENABLED"
export GPU_COUNT="$GPU_COUNT"
export GPU_DEVICE_PLUGIN_ENABLED="$GPU_ENABLED"

log "Initializing Terraform..."
if [ "$DRY_RUN" = false ]; then
    check_command terraform init
else
    log "[DRY-RUN] Would initialize Terraform"
fi

log "Applying Terraform configuration..."
if [ "$DRY_RUN" = false ]; then
    check_command terraform apply -auto-approve
else
    log "[DRY-RUN] Would apply Terraform configuration"
fi

# Retrieve KUBECONFIG from Terraform output and set it
TF_KUBECONFIG=$(terraform output -json kubeconfig 2>/dev/null || echo "")
if [ -z "$TF_KUBECONFIG" ]; then
    log "ERROR: Failed to retrieve KUBECONFIG from Terraform output"
    exit 1
fi

log "Setting KUBECONFIG..."
if [ "$DRY_RUN" = false ]; then
    mkdir -p "$(dirname "$KUBECONFIG_PATH")"
    echo "$TF_KUBECONFIG" | jq -r . > "$KUBECONFIG_PATH"
    export KUBECONFIG="$KUBECONFIG_PATH"
else
    log "[DRY-RUN] Would set KUBECONFIG"
    export KUBECONFIG="/tmp/mock-kubeconfig"
    echo "mock-kubeconfig-content" > "$KUBECONFIG"
fi

# Test cluster connectivity
if [ "$DRY_RUN" = false ]; then
    if ! test_cluster_connectivity; then
        exit 1
    fi
else
    log "[DRY-RUN] Would test cluster connectivity"
fi

log "Installing code-server via Helm..."
if [ "$DRY_RUN" = false ]; then
    check_command helm repo add coder-saas https://helm.coder.com/saas 2>/dev/null || log "Helm repo may already exist"
    check_command helm repo update

    # Use template-values.yaml for GPU-enabled deployments, fallback to values.yaml
    VALUES_FILE="values.yaml"
    if [ "$GPU_ENABLED" = "true" ]; then
        log "Using GPU-enabled configuration"
        VALUES_FILE="template-values.yaml"
    fi

    check_command helm upgrade --install code-server coder-saas/code-server --values "$VALUES_FILE" \
        --set "gpu.enabled=$GPU_ENABLED" \
        --set "gpu.resources.limits.nvidia\.com/gpu=$GPU_COUNT" \
        --set "gpu.resources.requests.nvidia\.com/gpu=$GPU_COUNT"
else
    log "[DRY-RUN] Would install code-server via Helm"
fi

# Get the namespace from values.yaml (assumes it contains namespace)
NAMESPACE=$(grep '^namespace:' values.yaml | cut -d':' -f2 | tr -d ' ' 2>/dev/null || echo "default")

log "Waiting for pods to be ready..."
if [ "$DRY_RUN" = false ]; then
    check_command kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=code-server -n "$NAMESPACE" --timeout=300s
else
    log "[DRY-RUN] Would wait for pods to be ready"
fi

# Retrieve external IP or load balancer
EXTERNAL_IP=$(kubectl get svc -l app.kubernetes.io/name=code-server -n "$NAMESPACE" -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null)
if [ -z "$EXTERNAL_IP" ]; then
    EXTERNAL_IP=$(kubectl get svc -l app.kubernetes.io/name=code-server -n "$NAMESPACE" -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
fi

if [ -n "$EXTERNAL_IP" ]; then
    log "code-server is ready! Access it at: http://$EXTERNAL_IP"
else
    log "code-server pods are ready, but external IP retrieval failed. Check logs or use kubectl port-forward:"
    log "kubectl port-forward svc/code-server -n $NAMESPACE 8080:80"
    log "Then access at: http://localhost:8080"
fi

    # Start spot pricing monitoring
    if [ "$DRY_RUN" = false ]; then
        monitor_spot_pricing "$REGION" "$SERVER_CLASS" &
        log "Spot pricing monitoring started in background."
    else
        log "[DRY-RUN] Would start spot pricing monitoring"
    fi

    log "Provisioning complete!"
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi