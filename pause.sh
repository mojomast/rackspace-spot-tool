#!/bin/bash

# Source helpers
source scripts/helpers.sh

# Pause script for code-server infrastructure on Rackspace Kubernetes
# This script safely pauses the environment by draining pods and scaling down node pools
# It is idempotent and includes logging and error handling

set -e  # Exit on any error
trap 'echo "Error occurred on line $LINENO. Exiting." >&2; exit 1' ERR

LOG_FILE="pause.log"
exec >> "$LOG_FILE" 2>&1  # Redirect all output to log file

# Function to log messages with consistent formatting
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

# Function to handle preemption monitoring
setup_preemption_webhook() {
    local cloudspace_id=$1
    local webhook_url="https://webhook.example.com/preemption-handler"  # Configure actual endpoint
    local resp=$(curl -s -w "\n%{http_code}" -X POST -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"url\": \"$webhook_url\", \"events\": [\"preemption\"], \"warningMinutes\": 5}" \
        "${SPOT_API_BASE%/}/webhooks/cloudspaces/${cloudspace_id}")
    local curl_exit=$?
    local http_code=$(echo "$resp" | tail -n1)
    local body=$(echo "$resp" | sed '$d')

    if [ $curl_exit -eq 0 ] && [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
        log "Preemption webhook configured successfully for cloudspace $cloudspace_id"
    elif [ "$http_code" -eq 429 ]; then
        log "WARNING: Rate limit hit for webhook setup - proceeding without"
    else
        log "WARNING: Failed to setup preemption webhook (${http_code})"
    fi
}

# Function to monitor for preemption during scaling
monitor_preemption_during_pause() {
    local cloudspace_id=$1
    local resp=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer ${TOKEN}" "${SPOT_API_BASE%/}/cloudspaces/$cloudspace_id/preemption/status")
    local curl_exit=$?
    local http_code=$(echo "$resp" | tail -n1)
    local body=$(echo "$resp" | sed '$d')

    if [ $curl_exit -eq 0 ] && [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
        if echo "$body" | jq -e '.preemptionNotice' >/dev/null 2>&1; then
            log "WARNING: Preemption notice detected during pause - immediate nodes may be terminated"
            log "Consider increasing bid price before resuming"
        fi
    else
        log "WARNING: Could not check preemption status (${http_code})"
    fi
}

log "Starting pause script"

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
log "Select the REGION for pause operation:"
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

# Prompt for KUBECONFIG_PATH with default
read -p "Enter KUBECONFIG_PATH (default: ~/.kube/config): " KUBECONFIG_PATH
KUBECONFIG_PATH="${KUBECONFIG_PATH:-~/.kube/config}"

# Validate KUBECONFIG_PATH existence
if [ ! -f "$KUBECONFIG_PATH" ]; then
    log "ERROR: KUBECONFIG_PATH file does not exist: $KUBECONFIG_PATH"
    exit 1
fi
log "Validated KUBECONFIG_PATH: $KUBECONFIG_PATH"

# Prompt for TERRAFORM_DIR with default
read -p "Enter TERRAFORM_DIR (default: ./): " TERRAFORM_DIR
TERRAFORM_DIR="${TERRAFORM_DIR:-./}"

# Validate TERRAFORM_DIR existence
if [ ! -d "$TERRAFORM_DIR" ]; then
    log "ERROR: TERRAFORM_DIR directory does not exist: $TERRAFORM_DIR"
    exit 1
fi
log "Validated TERRAFORM_DIR: $TERRAFORM_DIR"

# Export KUBECONFIG
export KUBECONFIG="$KUBECONFIG_PATH"
log "Exported KUBECONFIG to $KUBECONFIG_PATH"

# Assume namespace and label for code-server pods (can be customized)
NAMESPACE="code-server"  # Change as needed
LABEL_SELECTOR="app=code-server"  # Change as needed

# Drain code-server pods by draining their nodes
log "Finding nodes running code-server pods"
NODES=$(kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" -o jsonpath='{.items[*].spec.nodeName}' | tr ' ' '\n' | sort | uniq)
if [ -z "$NODES" ]; then
    log "INFO: No active code-server pods found. Skipping drain."
else
    log "INFO: Found nodes to drain: $NODES"
    for NODE in $NODES; do
        log "Draining node $NODE"
        # Use --ignore-daemonsets --pod-selector to avoid draining DS pods
        kubectl drain "$NODE" --force=false --ignore-daemonsets=false --delete-emptydir-data || log "WARNING: Failed to drain $NODE"
    done
fi

# Verify no running pods remain
log "Verifying no running pods remain"
RUNNING_PODS=$(kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" --field-selector=status.phase=Running -o name)
if [ -n "$RUNNING_PODS" ]; then
    log "ERROR: Pods still running: $RUNNING_PODS"
    exit 1
else
    log "INFO: No running code-server pods found."
fi

# Get cloudspace ID for preemption monitoring
log "Retrieving cloudspace information..."
resp=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer ${TOKEN}" "${SPOT_API_BASE%/}/cloudspaces/")
curl_exit=$?
http_code=$(echo "$resp" | tail -n1)
CLOUDSPECES_RESPONSE=$(echo "$resp" | sed '$d')

if [ $curl_exit -eq 0 ] && [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
    CLOUDSPECES_ID=$(echo "$CLOUDSPECES_RESPONSE" | jq -r ".[] | select(.region == \"$REGION\") | .id" | head -1)
    if [ -n "$CLOUDSPECES_ID" ]; then
        # Monitor for preemption before scaling down
        monitor_preemption_during_pause "$CLOUDSPECES_ID"
        # Setup webhook for future preemptions if configuring
        setup_preemption_webhook "$CLOUDSPECES_ID"
    else
        log "WARNING: No cloudspace found in $REGION"
    fi
else
    log "WARNING: Failed to retrieve cloudspaces (${http_code})"
    CLOUDSPECES_ID=""
fi

# Scale spot node pool to zero via Terraform
log "Scaling down node pool via Terraform"
cd "$TERRAFORM_DIR" || { log "ERROR: Failed to change directory to $TERRAFORM_DIR"; exit 1; }
# Assume variable file where node_count is defined, e.g., terraform.tfvars
TF_VARS_FILE="terraform.tfvars"
if [ -f "$TF_VARS_FILE" ]; then
    if grep -q "^node_count" "$TF_VARS_FILE"; then
        sed -i 's/^node_count = [0-9]\+/node_count = 0/' "$TF_VARS_FILE"
        log "INFO: Updated node_count to 0 in $TF_VARS_FILE"
    else
        log "WARNING: node_count not found in $TF_VARS_FILE. Assuming it's set elsewhere."
    fi
else
    log "WARNING: terraform.tfvars not found. Cannot update node_count."
fi
# Apply Terraform changes
log "Initializing Terraform"
check_command terraform init -input=false
log "Planning Terraform changes"
terraform plan -input=false || log "WARNING: terraform plan failed, continuing"
log "Applying Terraform changes"
check_command terraform apply -auto-approve
log "INFO: Terraform apply completed. Node pool scaled to zero."

log "SUCCESS: Pause script completed successfully"
echo "$(date '+%Y-%m-%d %H:%M:%S') - Script finished" >&2  # Also to stderr for user visibility