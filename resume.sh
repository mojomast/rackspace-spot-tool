#!/bin/bash

# Source helpers
source scripts/helpers.sh
#!/bin/bash

# resume.sh - Interactive script to resume a Kubernetes cluster using Terraform and Helm
# This script prompts for necessary credentials and paths, restores spot node count via Terraform,
# waits for resources to be ready, and redeploys Helm charts for code-server.

set -e  # Exit on any error for safety

# Parse command line arguments
DEBUG=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --debug)
            DEBUG=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--debug]"
            exit 1
            ;;
    esac
done
export DEBUG

# Function for logging with timestamps
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

# Function for error handling and cleanup
error_exit() {
    log "ERROR: $1"
    exit 1
}

# Function to validate spot API token
validate_spot_api_token() {
    local resp=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer ${TOKEN}" "${SPOT_API_BASE%/}/auth/validate")
    local curl_exit=$?
    local http_code=$(echo "$resp" | tail -n1)
    local body=$(echo "$resp" | sed '$d')

    if [ $curl_exit -eq 0 ] && [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
        if echo "$body" | jq -e '.valid' >/dev/null 2>&1; then
            log "API token validated successfully."
        else
            log "ERROR: Token validation response indicates invalid token."
            exit 1
        fi
    else
        local msg=$(echo "$body" | jq -r '.message // .error // .errors[0].message // "unknown"' 2>/dev/null || echo "unknown")
        echo "API error ${http_code}: $msg" >&2
        if [ "$DEBUG" = true ]; then
            echo "Full response: $body" >&2
        fi
        exit 1
    fi
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
    elif [ "$http_code" -eq 429 ]; then
        log "WARNING: Rate limit exceeded for market price fetch. Retrying..."
        sleep 5
        fetch_market_price "$region" "$server_class"
    else
        log "WARNING: Failed to fetch market price (${http_code}) - Using fallback"
        echo ""
    fi
}

# Function to optimize bid based on market
optimize_bid_price() {
    local region=$1
    local server_class=$2
    local current_bid=$3

    local market_price=$(fetch_market_price "$region" "$server_class")
    if [ -n "$market_price" ]; then
        local suggested_bid=$(echo "scale=3; $market_price * 1.1" | bc -l 2>/dev/null || echo "$market_price")
        log "Market price: $${market_price}, suggested bid: $${suggested_bid}"

        if [ $(echo "$current_bid < $market_price * 1.1" | bc -l 2>/dev/null) = 1 ]; then
            log "WARNING: Current bid $${current_bid} below recommended (market * 1.1)"
            read -p "Update bid to $${suggested_bid}? (y/n): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy] ]]; then
                echo "$suggested_bid"
                return
            fi
        fi
    fi
    echo "$current_bid"
}

# Prompt for SPOT_API_TOKEN
if [ -z "$SPOT_API_TOKEN" ]; then
    read -p "Enter SPOT_API_TOKEN: " SPOT_API_TOKEN
fi
if [ -z "$SPOT_API_TOKEN" ]; then
    log "ERROR: SPOT_API_TOKEN is required"
    exit 1
fi

# Get token
TOKEN=$(get_spot_token) || exit 1
log "API token provided (masked)"

# Validate API token
log "Validating API token..."
validate_spot_api_token

# Select REGION with interactive menu
log "Select the REGION for resume operation:"
echo "Generation-2:"
echo "1. us-west-sjc-1 (San Jose, CA) - GPU-enabled location"
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
select REGION_DESC in "us-west-sjc-1 (San Jose, CA) - GPU-enabled location" "us-central-dfw-1 (Dallas, TX)" "us-east-iad-1 (Ashburn, VA) - Coming Soon" "us-east-iad-1 (Ashburn, VA)" "us-central-dfw-1 (Dallas, TX)" "us-central-ord-1 (Chicago, IL)" "eu-west-lon-1 (London, UK)" "apac-se-syd-1 (Sydney, Australia)" "apac-se-hkg-1 (Hong Kong)"
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

# Prompts for SERVER_CLASS with generation filtering
echo "Select the SERVER_CLASS ($gen compatible):"
if [ "$gen" = "gen2" ]; then
  server_options=("gp1-medium (General Purpose 1)" "gp1-large (General Purpose 2)" "gp1-xlarge (General Purpose 3)" "gp1-2xlarge (General Purpose 4)" "gp1-4xlarge (General Purpose 5)" "ch1-large (Compute Heavy 7)" "ch1-xlarge (Compute Heavy 8)" "ch1-2xlarge (Compute Heavy 9)" "ch1-4xlarge (Compute Heavy 10)" "mh1-large (Memory Heavy 11)" "mh1-xlarge (Memory Heavy 12)" "mh1-2xlarge (Memory Heavy 13)" "mh1-4xlarge (Memory Heavy 14)" "gpu1-xlarge (GPU 15)" "gpu1-2xlarge (GPU 16)")
else
  server_options=("gp1-medium (General Purpose 1)" "gp1-large (General Purpose 2)" "gp1-xlarge (General Purpose 3)" "gp1-2xlarge (General Purpose 4)" "gp1-4xlarge (General Purpose 5)" "ch1-large (Compute Heavy 7)" "ch1-xlarge (Compute Heavy 8)" "ch1-2xlarge (Compute Heavy 9)" "ch1-4xlarge (Compute Heavy 10)" "mh1-large (Memory Heavy 11)" "mh1-xlarge (Memory Heavy 12)" "mh1-2xlarge (Memory Heavy 13)" "mh1-4xlarge (Memory Heavy 14)")
fi
PS3="Enter your choice: "
select SERVER_CLASS_DESC in "${server_options[@]}"
do
  if [ -n "$REPLY" ]; then
    if [[ "$REPLY" =~ ^[0-9]+$ ]] && [ "$REPLY" -ge 1 ] && [ "$REPLY" -le "${#server_options[@]}" ]; then
      SERVER_CLASS_DESC="${server_options[$((REPLY-1))]}"
      SERVER_CLASS=$(echo "$SERVER_CLASS_DESC" | cut -d' ' -f1)
      log "Selected SERVER_CLASS: $SERVER_CLASS ($gen)"
      # Fetch current bid from tfvars if exists
      TF_MARKET_PRICE=$(fetch_market_price "$REGION" "$SERVER_CLASS")
      if [ -n "$TF_MARKET_PRICE" ]; then
        log "Current market price for $SERVER_CLASS in $REGION: $${TF_MARKET_PRICE}"
      fi
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

# Prompt for KUBECONFIG_PATH with default
read -p "Enter KUBECONFIG_PATH [default: ~/.kube/config]: " KUBECONFIG_PATH
KUBECONFIG_PATH="${KUBECONFIG_PATH:-~/.kube/config}"

# Validate KUBECONFIG_PATH existence
if [ ! -f "$KUBECONFIG_PATH" ]; then
    log "ERROR: KUBECONFIG_PATH file does not exist: $KUBECONFIG_PATH"
    exit 1
fi
log "INFO: Validated KUBECONFIG_PATH: $KUBECONFIG_PATH"

# Prompt for TERRAFORM_DIR with default (assuming main.tf is in current dir)
read -p "Enter TERRAFORM_DIR [default: .]: " TERRAFORM_DIR
TERRAFORM_DIR="${TERRAFORM_DIR:-.}"

# Validate TERRAFORM_DIR existence
if [ ! -d "$TERRAFORM_DIR" ]; then
    log "ERROR: TERRAFORM_DIR directory does not exist: $TERRAFORM_DIR"
    exit 1
fi
log "INFO: Validated TERRAFORM_DIR: $TERRAFORM_DIR"

# Export token and kubeconfig
export SPOT_API_TOKEN
export KUBECONFIG="$KUBECONFIG_PATH"

log "INFO: Exported token and KUBECONFIG to $KUBECONFIG_PATH"

# Change to Terraform directory
cd "$TERRAFORM_DIR" || error_exit "Failed to change directory to $TERRAFORM_DIR"

# Check for tfvars file and prompt for node count if needed
TFVARS_FILE="terraform.tfvars"
if [[ -f "$TFVARS_FILE" ]]; then
    log "INFO: Found tfvars file: $TFVARS_FILE"
    # Check and optimize bid price
    if grep -q "^spot_bid\s*=" "$TFVARS_FILE"; then
        CURRENT_BID=$(grep "^spot_bid\s*=" "$TFVARS_FILE" | cut -d= -f2 | tr -d '[:space:]')
        OPTIMIZED_BID=$(optimize_bid_price "$REGION" "$SERVER_CLASS" "$CURRENT_BID")
        if [ "$OPTIMIZED_BID" != "$CURRENT_BID" ]; then
            sed -i "s/^spot_bid\s*=.*$/spot_bid = $OPTIMIZED_BID/" "$TFVARS_FILE"
            log "INFO: Updated spot_bid to $OPTIMIZED_BID in $TFVARS_FILE"
        fi
    fi
    # Assume node_count is defined; if not, prompt
    if ! grep -q "^node_count\s*=" "$TFVARS_FILE"; then
        read -p "Enter desired node count (not found in tfvars): " NODE_COUNT
        # Validate NODE_COUNT as integer
        if [[ -n "$NODE_COUNT" ]] && [[ "$NODE_COUNT" =~ ^[0-9]+$ ]]; then
            echo "node_count = $NODE_COUNT" >> "$TFVARS_FILE"
            log "INFO: Added node_count = $NODE_COUNT to $TFVARS_FILE"
        elif [[ -n "$NODE_COUNT" ]]; then
            log "ERROR: NODE_COUNT must be a positive integer, got: $NODE_COUNT"
            exit 1
        else
            log "ERROR: NODE_COUNT is required"
            exit 1
        fi
    else
        log "INFO: node_count found in $TFVARS_FILE"
    fi
else
    log "WARNING: tfvars file not found, creating one"
    read -p "Enter desired node count: " NODE_COUNT
    # Validate NODE_COUNT as integer
    if [[ -n "$NODE_COUNT" ]] && [[ "$NODE_COUNT" =~ ^[0-9]+$ ]]; then
        # Create tfvars with optimized bid
        OPTIMIZED_BID=$(optimize_bid_price "$REGION" "$SERVER_CLASS" "0.03") # default fallback
        cat > "$TFVARS_FILE" << EOF
node_count = $NODE_COUNT
region = "$REGION"
spot_bid = $OPTIMIZED_BID
EOF
        log "INFO: Created $TFVARS_FILE with node_count = $NODE_COUNT and spot_bid = $OPTIMIZED_BID"
    else
        log "ERROR: NODE_COUNT must be a positive integer, got: $NODE_COUNT"
        exit 1
    fi
fi

# Apply Terraform to restore spot node count
log "INFO: Initializing Terraform..."
check_command terraform init
log "INFO: Applying Terraform to restore nodes..."
check_command terraform apply -auto-approve

# Wait for nodes to join the cluster
log "Waiting for nodes to join the cluster..."
kubectl wait --for=condition=Ready node --all --timeout=300s || error_exit "Nodes failed to join within timeout"

# Assume PVC name is known or list and wait; customize as needed
log "Waiting for PVC to bind..."
kubectl wait --for=condition=bound pvc --all --timeout=300s || error_exit "PVC binding failed within timeout"

# Re-apply Helm for code-server using values.yaml (assume helm chart name and release)
# Replace 'code-server' with actual release name if different
log "INFO: Upgrading/reinstalling Helm release for code-server..."
check_command helm upgrade --install code-server ./helm/code-server --values values.yaml

# Wait for pods to be ready
log "Waiting for code-server pods to be ready..."
kubectl wait --for=condition=Ready pod -l app=code-server --timeout=300s || error_exit "Pods failed to ready within timeout"

# Print external IP or suggest port-forward
SERVICE_IP=$(kubectl get svc code-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
if [[ -n "$SERVICE_IP" ]]; then
    log "External IP: $SERVICE_IP"
    echo "Access code-server at http://$SERVICE_IP"
else
    log "No external IP found; use port-forward"
    echo "Run: kubectl port-forward svc/code-server 8080:80"
fi

log "SUCCESS: Resume script completed successfully"