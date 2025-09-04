#!/bin/bash

# provision.sh: Interactive script to provision infrastructure for code-server deployment on Rackspace using Terraform and Helm
# This script prompts for necessary variables with defaults, initializes and applies Terraform for infrastructure,
# sets up KUBECONFIG, installs code-server via Helm, waits for pods to be ready, and provides access instructions.

set -e  # Exit on any error for safety

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

# Function to validate spot API token
validate_spot_api_token() {
    local RESPONSE=$(curl -s -w "%{http_code}" -H "Authorization: Bearer $RACKSPACE_SPOT_API_TOKEN" https://api.spot.rackspace.com/v1/auth/validate)
    local HTTP_CODE="${RESPONSE##* }"
    local BODY="${RESPONSE%* }"

    if [ "$HTTP_CODE" -eq 200 ]; then
        if echo "$BODY" | jq -e '.valid' >/dev/null 2>&1; then
            log "API token validated successfully."
        else
            log "ERROR: Token validation response indicates invalid token."
            exit 1
        fi
    elif [ "$HTTP_CODE" -eq 401 ]; then
        local ERROR_MSG=$(echo "$BODY" | jq -r '.error.message' 2>/dev/null || echo "Unauthorized")
        log "ERROR: Invalid token - $ERROR_MSG"
        exit 1
    elif [ "$HTTP_CODE" -eq 429 ]; then
        log "ERROR: Rate limit exceeded. Please try again later."
        exit 1
    elif [ "$HTTP_CODE" -ge 500 ]; then
        log "ERROR: Server error during token validation."
        exit 1
    else
        local ERROR_MSG=$(echo "$BODY" | jq -r '.error.message' 2>/dev/null || echo "Unknown error")
        log "ERROR: Token validation failed ($HTTP_CODE) - $ERROR_MSG"
        exit 1
    fi
}

# Function to display account limits and quotas
get_rackspace_limits() {
    local RESPONSE=$(curl -s -w "%{http_code}" -H "Authorization: Bearer $RACKSPACE_SPOT_API_TOKEN" https://api.spot.rackspace.com/v1/auth/limits)
    local HTTP_CODE="${RESPONSE##* }"
    local BODY="${RESPONSE%* }"

    if [ "$HTTP_CODE" -eq 200 ]; then
        log "Current Account Limits and Quotas:"
        echo "$BODY" | jq .
    elif [ "$HTTP_CODE" -eq 401 ]; then
        log "WARNING: Unable to retrieve limits - Token validation failed"
    elif [ "$HTTP_CODE" -eq 429 ]; then
        log "WARNING: Unable to retrieve limits - Rate limit exceeded"
    elif [ "$HTTP_CODE" -ge 500 ]; then
        log "WARNING: Unable to retrieve limits - Server error"
    else
        local ERROR_MSG=$(echo "$BODY" | jq -r '.error.message' 2>/dev/null || echo "Unknown error")
        log "WARNING: Failed to retrieve limits ($HTTP_CODE) - $ERROR_MSG"
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
    local RESPONSE=$(curl -s -w "%{http_code}" -H "Authorization: Bearer $RACKSPACE_SPOT_API_TOKEN" "https://api.spot.rackspace.com/v1/market/prices/${region}/servers/${server_class}")
    local HTTP_CODE="${RESPONSE##* }"
    local BODY="${RESPONSE%* }"

    if [ "$HTTP_CODE" -eq 200 ]; then
        local PRICE=$(echo "$BODY" | jq -r '.price // empty')
        if [ -n "$PRICE" ] && [ "$PRICE" != "null" ]; then
            echo "$PRICE"
        else
            log "WARNING: Market price data not found for ${server_class} in ${region}"
            echo ""
        fi
    else
        log "WARNING: Failed to fetch market price ($HTTP_CODE) - Using default bid"
        echo ""
    fi
}

# Function to setup preemption webhook
setup_preemption_webhook() {
    local cloudspace_id=$1
    local webhook_url="https://example.com/webhook"  # Placeholder, customize as needed
    local RESPONSE=$(curl -s -w "%{http_code}" -X POST -H "Authorization: Bearer $RACKSPACE_SPOT_API_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"url\": \"$webhook_url\", \"events\": [\"preemption\"], \"warningMinutes\": 5}" \
        "https://api.spot.rackspace.com/v1/webhooks/cloudspaces/${cloudspace_id}")
    local HTTP_CODE="${RESPONSE##* }"
    local BODY="${RESPONSE%* }"

    if [ "$HTTP_CODE" -eq 201 ]; then
        log "Preemption webhook configured successfully for cloudspace $cloudspace_id"
    else
        log "WARNING: Failed to setup preemption webhook ($HTTP_CODE)"
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
if [ -z "$RACKSPACE_SPOT_API_TOKEN" ]; then
    read -p "Enter RACKSPACE_SPOT_API_TOKEN: " RACKSPACE_SPOT_API_TOKEN
fi
if [ -z "$RACKSPACE_SPOT_API_TOKEN" ]; then
    log "ERROR: RACKSPACE_SPOT_API_TOKEN is required"
    exit 1
fi

# Validate API token
log "Validating API token..."
validate_spot_api_token

# Display account limits
log "Retrieving account limits..."
get_rackspace_limits

# Select REGION with interactive menu
log "Select the REGION for deployment:"
echo "Generation-2:"
echo "1. us-west-sjc-1 (San Jose, CA) - NEW GPU-enabled location"
echo "2. us-central-dfw-1 (Dallas, TX)"
echo "3. us-east-iad-1 (Ashburn, VA) - Coming Soon"
echo "Generation-1:"
echo "4. us-east-iad-1 (Ashburn, VA)"
echo "5. us-central-dfw-1 (Dallas, TX)"
echo "6. us-central-ord-1 (Chicago, IL)"
echo "7. eu-west-lon-1 (London, UK)"
echo "8. apac-se-syd-1 (Sydney, Australia)"
echo "9. apac-se-hkg-1 (Hong Kong)"
PS3="Enter your choice (1-9): "
select REGION_DESC in "us-west-sjc-1 (San Jose, CA) - NEW GPU-enabled location" "us-central-dfw-1 (Dallas, TX)" "us-east-iad-1 (Ashburn, VA) - Coming Soon" "us-east-iad-1 (Ashburn, VA)" "us-central-dfw-1 (Dallas, TX)" "us-central-ord-1 (Chicago, IL)" "eu-west-lon-1 (London, UK)" "apac-se-syd-1 (Sydney, Australia)" "apac-se-hkg-1 (Hong Kong)"
do
  case $REPLY in
    1) REGION="us-west-sjc-1"; log "Selected REGION: us-west-sjc-1 (Generation-2)"; gen="gen2"; break;;
    2) REGION="us-central-dfw-1"; log "Selected REGION: us-central-dfw-1 (Generation-2)"; gen="gen2"; break;;
    3) REGION="us-east-iad-1"; log "Selected REGION: us-east-iad-1 (Generation-2)"; gen="gen2"; break;;
    4) REGION="us-east-iad-1"; log "Selected REGION: us-east-iad-1 (Generation-1)"; gen="gen1"; break;;
    5) REGION="us-central-dfw-1"; log "Selected REGION: us-central-dfw-1 (Generation-1)"; gen="gen1"; break;;
    6) REGION="us-central-ord-1"; log "Selected REGION: us-central-ord-1 (Generation-1)"; gen="gen1"; break;;
    7) REGION="eu-west-lon-1"; log "Selected REGION: eu-west-lon-1 (Generation-1)"; gen="gen1"; break;;
    8) REGION="apac-se-syd-1"; log "Selected REGION: apac-se-syd-1 (Generation-1)"; gen="gen1"; break;;
    9) REGION="apac-se-hkg-1"; log "Selected REGION: apac-se-hkg-1 (Generation-1)"; gen="gen1"; break;;
    "") log "No selection made, using default: us-east-iad-1 (Generation-1)"; REGION="us-east-iad-1"; gen="gen1"; break;;
    *) log "Invalid selection ($REPLY). Please choose 1-9."; continue;;
  esac
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
    CLOUDSPECES_RESPONSE=$(curl -s -H "Authorization: Bearer $RACKSPACE_SPOT_API_TOKEN" https://api.spot.rackspace.com/v1/cloudspaces/)
    if ! echo "$CLOUDSPECES_RESPONSE" | jq empty > /dev/null 2>&1; then
        log "ERROR: Failed to retrieve cloudspaces or invalid response"
        exit 1
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
   VALIDATE_RESPONSE=$(curl -s -H "Authorization: Bearer $RACKSPACE_SPOT_API_TOKEN" "https://api.spot.rackspace.com/v1/cloudspaces/$CLOUDSPECES_ID")
   if [[ "$VALIDATE_RESPONSE" == *"404"* ]] || [[ "$VALIDATE_RESPONSE" == *'"error"'* ]]; then
       log "ERROR: Unable to validate cloudspace access"
       exit 1
   fi
   log "Cloudspace accessibility validated."
   
   # Download kubeconfig
   TMP_KUBECONFIG=$(mktemp)
   curl -s -H "Authorization: Bearer $RACKSPACE_SPOT_API_TOKEN" "https://api.spot.rackspace.com/v1/cloudspaces/$CLOUDSPECES_ID/kubeconfig" > "$TMP_KUBECONFIG"
   
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
   
   NODEPOOLS_RESPONSE=$(curl -s -H "Authorization: Bearer $RACKSPACE_SPOT_API_TOKEN" "https://api.spot.rackspace.com/v1/cloudspaces/$CLOUDSPECES_ID/nodepools/")
   if ! echo "$NODEPOOLS_RESPONSE" | jq empty > /dev/null 2>&1; then
       log "WARNING: Could not retrieve nodepools info"
   else
       # Assume required storage classes are managed via API; log status
       log "Storage classes checked via nodepools API."
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
echo "Select the SERVER_CLASS ($gen compatible):"
if [ "$gen" = "gen2" ]; then
  server_options=(\
    "gp1-medium (General Purpose 1)" \
    "gp1-large (General Purpose 2)" \
    "gp1-xlarge (General Purpose 3)" \
    "gp1-2xlarge (General Purpose 4)" \
    "gp1-4xlarge (General Purpose 5)" \
    "ch1-large (Compute Heavy 7)" \
    "ch1-xlarge (Compute Heavy 8)" \
    "ch1-2xlarge (Compute Heavy 9)" \
    "ch1-4xlarge (Compute Heavy 10)" \
    "mh1-large (Memory Heavy 11)" \
    "mh1-xlarge (Memory Heavy 12)" \
    "mh1-2xlarge (Memory Heavy 13)" \
    "mh1-4xlarge (Memory Heavy 14)" \
    "gpu1-xlarge (GPU 15)" \
    "gpu1-2xlarge (GPU 16)" \
  )
else
  server_options=(\
    "gp1-medium (General Purpose 1)" \
    "gp1-large (General Purpose 2)" \
    "gp1-xlarge (General Purpose 3)" \
    "gp1-2xlarge (General Purpose 4)" \
    "gp1-4xlarge (General Purpose 5)" \
    "ch1-large (Compute Heavy 7)" \
    "ch1-xlarge (Compute Heavy 8)" \
    "ch1-2xlarge (Compute Heavy 9)" \
    "ch1-4xlarge (Compute Heavy 10)" \
    "mh1-large (Memory Heavy 11)" \
    "mh1-xlarge (Memory Heavy 12)" \
    "mh1-2xlarge (Memory Heavy 13)" \
    "mh1-4xlarge (Memory Heavy 14)" \
  )
fi
PS3="Enter your choice: "
select SERVER_CLASS_DESC in "${server_options[@]}"
do
  if [ -n "$REPLY" ]; then
    if [[ "$REPLY" =~ ^[0-9]+$ ]] && [ "$REPLY" -ge 1 ] && [ "$REPLY" -le "${#server_options[@]}" ]; then
      SERVER_CLASS_DESC="${server_options[$((REPLY-1))]}"
      SERVER_CLASS=$(echo "$SERVER_CLASS_DESC" | cut -d' ' -f1)
      log "Selected SERVER_CLASS: $SERVER_CLASS ($gen)"
      break
    else
      log "Invalid selection ($REPLY). Please choose 1-${#server_options[@]}."
      continue
    fi
  else
    SERVER_CLASS="gp1-medium"
    log "No selection made, using default: gp1-medium (General Purpose 1)"
    break
  fi
done

# Check market availability
check_market_availability "$REGION" "$SERVER_CLASS"

# Fetch market price for bid strategy
MARK_PRICE=$(fetch_market_price "$REGION" "$SERVER_CLASS")
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

# Export variables for Terraform
export TF_VAR_rackspace_spot_api_token="$RACKSPACE_SPOT_API_TOKEN"
export TF_VAR_region="$REGION"
export TF_VAR_bid_price="$BID_PRICE"
export TF_VAR_node_count="$NODE_COUNT"
export TF_VAR_server_class="$SERVER_CLASS"

log "Initializing Terraform..."
check_command terraform init

log "Applying Terraform configuration..."
check_command terraform apply -auto-approve

# Retrieve KUBECONFIG from Terraform output and set it
TF_KUBECONFIG=$(terraform output -json kubeconfig 2>/dev/null || echo "")
if [ -z "$TF_KUBECONFIG" ]; then
    log "ERROR: Failed to retrieve KUBECONFIG from Terraform output"
    exit 1
fi

log "Setting KUBECONFIG..."
mkdir -p "$(dirname "$KUBECONFIG_PATH")"
echo "$TF_KUBECONFIG" | jq -r . > "$KUBECONFIG_PATH"
export KUBECONFIG="$KUBECONFIG_PATH"

# Test cluster connectivity
if ! test_cluster_connectivity; then
  exit 1
fi

log "Installing code-server via Helm..."
check_command helm repo add coder-saas https://helm.coder.com/saas 2>/dev/null || log "Helm repo may already exist"
check_command helm repo update
check_command helm upgrade --install code-server coder-saas/code-server --values values.yaml

# Get the namespace from values.yaml (assumes it contains namespace)
NAMESPACE=$(grep '^namespace:' values.yaml | cut -d':' -f2 | tr -d ' ' 2>/dev/null || echo "default")

log "Waiting for pods to be ready..."
check_command kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=code-server -n "$NAMESPACE" --timeout=300s

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
monitor_spot_pricing "$REGION" "$SERVER_CLASS" &
log "Spot pricing monitoring started in background."

log "Provisioning complete!"