#!/bin/bash

# Source helpers
source scripts/helpers.sh
#!/bin/bash

# deploy-code-server.sh: Interactive script to deploy code-server into the provisioned Kubernetes cluster
# Assumes Terraform has created cloudspace, node pool, PVC, and kubeconfig. This script installs code-server via Helm.
# Prompts for required values, validates inputs, sets namespace, adds Helm repo, generates values.yaml, runs Helm install, and handles service access.

main() {
    set -e  # Exit on any error for safety

    # Parse command line arguments
    DRY_RUN=false
    DEBUG=false
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
            *)
                echo "Unknown option: $1"
                echo "Usage: $0 [--dry-run] [--debug]"
                exit 1
                ;;
            esac
            done

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
# Export DEBUG for helpers
export DEBUG

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
        log "WARNING: Failed to fetch market price (${http_code}) - Using default"
        echo ""
    fi
}
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
            return 0
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

# Check if SPOT_API_TOKEN is set and validate
if [ -n "$SPOT_API_TOKEN" ]; then
    log "Validating existing SPOT_API_TOKEN..."
    if [ "$DRY_RUN" = false ]; then
        validate_spot_api_token
        get_rackspace_limits
    else
        log "[DRY-RUN] Would validate SPOT_API_TOKEN"
    fi
else
    log "Assuming token can be obtained via environment or defaults."
fi

# Get token
TOKEN=$(get_spot_token) || exit 1

# Ensure organization namespace is set and accessible
if [ -z "$SPOT_ORG_NAMESPACE" ]; then
    read -p "Enter SPOT_ORG_NAMESPACE: " SPOT_ORG_NAMESPACE
fi
if [ "$DRY_RUN" = false ]; then
    ensure_org_namespace || exit 1
else
    log "[DRY-RUN] Would validate organization namespace"
fi

# Default values for prompts
DEFAULT_NAMESPACE="code-server"
DEFAULT_STORAGE_SIZE="10Gi"
DEFAULT_SERVICE_TYPE="LoadBalancer"
DEFAULT_TIMEZONE="UTC"

# Step 1: Prompt for KUBECONFIG_PATH to set cluster context
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
        # Validate organization/namespace
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

    # Get kubeconfig using spot_kubeconfig data source
    if [ "$DRY_RUN" = false ]; then
        TMP_KUBECONFIG=$(mktemp)
        TMP_TF_DIR=$(mktemp -d)
        cat > "$TMP_TF_DIR/main.tf" <<EOF
terraform {
  required_providers {
    spot = {
      source = "rackerlabs/spot"
      version = "~> 0.1.4"
    }
  }
}

provider "spot" {
  token = var.spot_token
}

data "spot_kubeconfig" "main" {
  cloudspace_name = var.cloudspace_name
}

output "kubeconfig" {
  value = data.spot_kubeconfig.main.raw
  sensitive = true
}
EOF

        cat > "$TMP_TF_DIR/terraform.tfvars" <<EOF
spot_token = "${TOKEN}"
cloudspace_name = "${CLOUDSPECES_ID}"
EOF

        cd "$TMP_TF_DIR"
        terraform init -no-color > /dev/null 2>&1
        terraform apply -auto-approve -no-color > /dev/null 2>&1
        terraform output -raw kubeconfig > "$TMP_KUBECONFIG"
        cd - > /dev/null
        rm -rf "$TMP_TF_DIR"
    else
        log "[DRY-RUN] Would get kubeconfig using spot_kubeconfig data source"
        TMP_KUBECONFIG=$(mktemp)
        echo "mock-kubeconfig-content" > "$TMP_KUBECONFIG"
    fi

    if [ ! -f "$TMP_KUBECONFIG" ] || [ ! -s "$TMP_KUBECONFIG" ]; then
        log "ERROR: Failed to download kubeconfig"
        rm -f "$TMP_KUBECONFIG"
        exit 1
    fi

    # Identify gen from response
    GEN=$(jq -r '.generation' <<< "$VALIDATE_RESPONSE" || echo "gen1")
    GEN=${GEN,,}
    log "Detected generation: $GEN"

    # Select STORAGE_CLASS based on generation (needed for deployment)
    if [ "$GEN" = "gen2" ]; then
      storage_options=(\
        "gen2-storage1 (Storage Class 5)" \
        "gen2-storage2 (Storage Class 6)" \
      )
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
          log "Selected STORAGE_CLASS: $STORAGE_CLASS_DESC ($GEN)"
          break
        else
          log "Invalid selection ($REPLY). Please choose 1-${#storage_options[@]}."
          continue
        fi
      else
        if [ "$GEN" = "gen2" ]; then
          STORAGE_CLASS="gen2-storage1"
          log "No selection made, using default: gen2-storage1 (Storage Class 5)"
        else
          STORAGE_CLASS="gen1-storage1"
          log "No selection made, using default: gen1-storage1 (Storage Class 1)"
        fi
        break
      fi
    done

    # Set storage size based on selection
    case "$STORAGE_CLASS" in
      "gen1-storage1") STORAGE_SIZE="10Gi" ;;
      "gen1-storage2") STORAGE_SIZE="20Gi" ;;
      "gen1-storage3") STORAGE_SIZE="50Gi" ;;
      "gen1-storage4") STORAGE_SIZE="100Gi" ;;
      "gen2-storage1") STORAGE_SIZE="10Gi" ;;
      "gen2-storage2") STORAGE_SIZE="20Gi" ;;
      *) STORAGE_SIZE="10Gi" ;;
    esac
    log "Using STORAGE_SIZE: $STORAGE_SIZE based on STORAGE_CLASS: $STORAGE_CLASS"

    # Check storage classes
    if [ "$DRY_RUN" = false ]; then
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
            log "Storage classes checked via nodepools API."
        else
            log "WARNING: Could not retrieve nodepools info (${http_code})"
        fi
    else
        log "[DRY-RUN] Would check storage classes via nodepools API"
    fi

    # Set KUBECONFIG
    KUBECONFIG_PATH="$TMP_KUBECONFIG"
    log "KUBECONFIG_PATH set to temporary kubeconfig."

else
    # Existing logic for creating new deployment
# Select SERVER_CLASS with interactive menu
log "Fetching server classes for region $REGION..."
if [ "$DRY_RUN" = false ]; then
  SERVER_LIST=$(get_serverclasses "$REGION")
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
# Select STORAGE_CLASS based on generation
echo "Select the STORAGE_CLASS ($gen compatible):"
if [ "$gen" = "gen2" ]; then
  storage_options=(\
    "gen2-storage1 (Storage Class 5)" \
    "gen2-storage2 (Storage Class 6)" \
  )
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
# Determine STORAGE_SIZE based on STORAGE_CLASS
case "$STORAGE_CLASS" in
  "gen1-storage1") STORAGE_SIZE="10Gi" ;;
  "gen1-storage2") STORAGE_SIZE="20Gi" ;;
  "gen1-storage3") STORAGE_SIZE="50Gi" ;;
  "gen1-storage4") STORAGE_SIZE="100Gi" ;;
  "gen2-storage1") STORAGE_SIZE="10Gi" ;;
  "gen2-storage2") STORAGE_SIZE="20Gi" ;;
  *) STORAGE_SIZE="10Gi" ;;
esac
log "Using STORAGE_SIZE: $STORAGE_SIZE based on STORAGE_CLASS: $STORAGE_CLASS"
    break
  fi
done
PS3="Enter your choice: "
select SERVER_CLASS in "${SERVER_ARRAY[@]}"
do
  if [ -n "$REPLY" ]; then
    if [[ "$REPLY" =~ ^[0-9]+$ ]] && [ "$REPLY" -ge 1 ] && [ "$REPLY" -le "${#SERVER_ARRAY[@]}" ]; then
      SERVER_CLASS="${SERVER_ARRAY[$((REPLY-1))]}"
      log "Selected SERVER_CLASS: $SERVER_CLASS ($gen)"

      # Detect GPU capabilities from selected server class (for existing deployment)
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
# Fetch market price for Spot-specific display
if [ "$DRY_RUN" = false ]; then
    MARK_PRICE=$(fetch_market_price "$REGION" "$SERVER_CLASS")
else
    log "[DRY-RUN] Would fetch market price for $SERVER_CLASS in $REGION"
    MARK_PRICE="0.05"  # Mock price for dry-run
fi
if [ -n "$MARK_PRICE" ]; then
    log "Market price for $SERVER_CLASS: stash$\MARK_PRICE"
else
    log "Market price unavailable"
fi
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
fi
if [ "$DEPLOYMENT_OPTION" != "Use existing" ]; then
echo "Select KUBECONFIG_PATH (kubeconfig file for cluster access):"
echo "  - ~/.kube/config: Default user kubeconfig"
echo "  - /etc/kubernetes/admin.conf: Admin config (e.g., in-cluster)"
echo "  - Custom path: Enter your own path"
echo "  - Cancel: Exit script"
select KUBECONFIG_PATH in "$HOME/.kube/config" "/etc/kubernetes/admin.conf" "Custom path" "Cancel"; do
    case $KUBECONFIG_PATH in
        "$HOME/.kube/config"|"/etc/kubernetes/admin.conf")
            break;;
        "Custom path")
            read -p "Enter custom KUBECONFIG_PATH: " KUBECONFIG_PATH
            break;;
        "Cancel")
            log "Cancelled by user"
            exit 0;;
        *)
            echo "Invalid option. Please select 1-4.";;
    esac
done
if [ -z "$KUBECONFIG_PATH" ] || [ ! -f "$KUBECONFIG_PATH" ]; then
    log "ERROR: KUBECONFIG_PATH is required and file must exist"
fi
    exit 1
fi

# Export KUBECONFIG to connect to the cluster
export KUBECONFIG="$KUBECONFIG_PATH"

log "Using KUBECONFIG: $KUBECONFIG_PATH"

# Test cluster connectivity
if [ "$DRY_RUN" = false ]; then
    if ! test_cluster_connectivity; then
        exit 1
    fi
    # Validate kubeconfig by checking cluster connection
    check_command kubectl cluster-info
    log "Successfully connected to Kubernetes cluster"
else
    log "[DRY-RUN] Would test cluster connectivity and validate kubeconfig"
fi

# Step 2: Prompt for NAMESPACE with default
read -p "Enter NAMESPACE [$DEFAULT_NAMESPACE]: " NAMESPACE
NAMESPACE=${NAMESPACE:-$DEFAULT_NAMESPACE}

# Validate namespace name (basic check)
if [[ ! "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    log "ERROR: Invalid NAMESPACE format. Must be lowercase alphanumeric"
    exit 1
fi

# Ensure namespace exists, create if missing
if ! kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
    log "Creating namespace: $NAMESPACE"
    check_command kubectl create ns "$NAMESPACE"
else
    log "Namespace $NAMESPACE already exists"
fi

# Step 3: Prompt for CODE_SERVER_PASSWORD (masked input)
read -s -p "Enter CODE_SERVER_PASSWORD: " CODE_SERVER_PASSWORD
echo ""  # Newline after hidden input
if [ -z "$CODE_SERVER_PASSWORD" ]; then
    log "ERROR: CODE_SERVER_PASSWORD is required"
    exit 1
fi

# Step 4: Prompt for STORAGE_SIZE with default
read -p "Enter STORAGE_SIZE [$DEFAULT_STORAGE_SIZE]: " STORAGE_SIZE
STORAGE_SIZE=${STORAGE_SIZE:-$DEFAULT_STORAGE_SIZE}

# Basic validation for storage size
if [[ ! "$STORAGE_SIZE" =~ ^[0-9]+(Gi|Mi)$ ]]; then
    log "ERROR: STORAGE_SIZE must be in format [number](Gi|Mi), e.g., 10Gi"
    exit 1
fi

# Step 5: Prompt for TIMEZONE with default
echo "Select TIMEZONE (affects code-server timestamps and logs):"
echo "  - UTC: Coordinated Universal Time (recommended for consistency)"
echo "  - America/New_York: Eastern Time"
echo "  - Europe/London: Greenwich Mean Time"
echo "  - Asia/Tokyo: Japan Standard Time"
echo "  - America/Los_Angeles: Pacific Time"
echo "  - Europe/Paris: Central European Time"
declare -a tz_options=("UTC" "America/New_York" "Europe/London" "Asia/Tokyo" "America/Los_Angeles" "Europe/Paris")
select TIMEZONE in "${tz_options[@]}"; do
    if [ -n "$TIMEZONE" ]; then
        break
    else
        echo "Invalid option. Please select 1-6."
    fi
done

# Basic validation for timezone
if ! echo "$TIMEZONE" | grep -qE "^[A-Z][a-z_]+(/[A-Z][a-z_]+)?$"; then
    log "ERROR: Invalid TIMEZONE format, e.g., UTC, America/New_York"
    exit 1
fi

# Step 6: Prompt for SERVICE_TYPE with default
echo "Select SERVICE_TYPE (determines how code-server is exposed):"
echo "  - LoadBalancer: External access via public IP (e.g., for internet access)"
echo "  - ClusterIP: Internal access within cluster only (secure for private use)"
select SERVICE_TYPE in "LoadBalancer" "ClusterIP"; do
    case $SERVICE_TYPE in
        "LoadBalancer"|"ClusterIP")
            break;;
        *)
            echo "Invalid option. Please select 1 or 2.";;
    esac
done

# Step 7: Add coder-saas Helm repo (idempotent)
log "Adding coder-saas Helm repo for code-server"
helm repo add coder-saas https://helm.coder.com/saas >/dev/null 2>&1 || log "Helm repo may already exist"
check_command helm repo update
log "Helm repo updated successfully"

# Step 8: Generate values.yaml from template
log "Generating values.yaml file from template"
cp template-values.yaml deploy-values.yaml

# Replace placeholders with prompted values
sed -i "s/\${STORAGE_SIZE}/$STORAGE_SIZE/g" deploy-values.yaml
sed -i "s/\${CODE_SERVER_PASSWORD}/$CODE_SERVER_PASSWORD/g" deploy-values.yaml
sed -i "s/\${TIMEZONE}/$TIMEZONE/g" deploy-values.yaml
sed -i "s/\${SERVICE_TYPE}/$SERVICE_TYPE/g" deploy-values.yaml
sed -i "s/\${GPU_ENABLED}/${GPU_ENABLED:-false}/g" deploy-values.yaml
sed -i "s/\${GPU_COUNT}/${GPU_COUNT:-0}/g" deploy-values.yaml
sed -i "s/\${GPU_DEVICE_PLUGIN_ENABLED}/${GPU_ENABLED:-false}/g" deploy-values.yaml

# Add Spot-specific environment variables
if [ -n "$REGION" ]; then
    sed -i "s/\${SPOT_REGION}/$REGION/g" deploy-values.yaml
fi
if [ -n "$gen" ]; then
    sed -i "s/\${SPOT_GENERATION}/$gen/g" deploy-values.yaml
fi
sed -i "s/\${SPOT_WEBHOOK_URL}/https:\/\/webhook.example.com\/preemption/g" deploy-values.yaml

log "values.yaml generated successfully"

# Step 9: Run Helm install/upgrade for code-server
if [ "$DRY_RUN" = false ]; then
    log "Installing/upgrading code-server via Helm"
    HELM_CMD="helm upgrade --install code-server coder-saas/code-server --namespace \"$NAMESPACE\" --values deploy-values.yaml"
    if [ "$GPU_ENABLED" = "true" ]; then
        HELM_CMD="$HELM_CMD --set gpu.enabled=true"
        HELM_CMD="$HELM_CMD --set gpu.resources.limits.nvidia\\.com/gpu=$GPU_COUNT"
        HELM_CMD="$HELM_CMD --set gpu.resources.requests.nvidia\\.com/gpu=$GPU_COUNT"
    fi
    check_command eval "$HELM_CMD"
    log "Helm command executed successfully"
else
    log "[DRY-RUN] Would install/upgrading code-server via Helm"
fi

# Step 10: Wait for pods to be ready
log "Waiting for code-server pods to be ready..."
check_command kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=code-server -n "$NAMESPACE" --timeout=300s
log "Pods are ready"

# VS Code Access Configuration Wizard

# Step 11: Detect service type and configure access
log "Detecting service type..."
SERVICE_TYPE_DETECTED=$(kubectl get svc code-server -n "$NAMESPACE" -o jsonpath='{.spec.type}' 2>/dev/null || echo "ClusterIP")
log "Detected service type: $SERVICE_TYPE_DETECTED"

if [ "$SERVICE_TYPE_DETECTED" = "LoadBalancer" ]; then
    log "Polling for external IP..."
    start_time=$(date +%s)
    timeout=300
    EXTERNAL_IP=""
    while [ $timeout -gt 0 ]; do
        EXTERNAL_IP=$(kubectl get svc code-server -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        if [ -z "$EXTERNAL_IP" ]; then
            EXTERNAL_IP=$(kubectl get svc code-server -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
        fi
        if [ -n "$EXTERNAL_IP" ]; then
            log "External IP detected: $EXTERNAL_IP"
            break
        fi
        sleep 10
        current_time=$(date +%s)
        elapsed=$((current_time - start_time))
        timeout=$((300 - elapsed))
        log "Waiting for external IP... (remaining time: ${timeout}s)"
    done

    if [ -n "$EXTERNAL_IP" ]; then
        ACCESS_IP="$EXTERNAL_IP"
        ACCESS_PORT=80
        ACCESS_URL="http://$ACCESS_IP:$ACCESS_PORT"
        log "SUCCESS: Access URL: $ACCESS_URL"

        # Generate browser bookmark file
        BOOKMARK_FILE="code-server-$NAMESPACE.url"
        echo "[InternetShortcut]" > "$BOOKMARK_FILE"
        echo "URL=$ACCESS_URL" >> "$BOOKMARK_FILE"
        echo "IconIndex=0" >> "$BOOKMARK_FILE"
        echo "HotKey=0" >> "$BOOKMARK_FILE"
        log "Generated browser bookmark file: $BOOKMARK_FILE (for Windows browsers)"

    else
        log "ERROR: External IP not available after 300s timeout"
        log "Check service status: kubectl get svc code-server -n $NAMESPACE"
        log "Manual access: kubectl port-forward -n $NAMESPACE svc/code-server 8080:80"
        ACCESS_IP="N/A"
        ACCESS_PORT="N/A"
        ACCESS_URL="N/A"
    fi

elif [ "$SERVICE_TYPE_DETECTED" = "ClusterIP" ]; then
    log "Starting background port-forward..."
    kubectl port-forward -n "$NAMESPACE" svc/code-server 8080:80 &
    PORT_FORWARD_PID=$!
    sleep 2  # Allow time for port-forward to start
    if ! ps -p $PORT_FORWARD_PID > /dev/null 2>&1; then
        log "ERROR: Port-forward failed to start"
        exit 1
    fi
    log "Port-forward started with PID: $PORT_FORWARD_PID"
    log "Run 'kill $PORT_FORWARD_PID' to stop port-forward"

    ACCESS_IP="localhost"
    ACCESS_PORT=8080
    ACCESS_URL="http://$ACCESS_IP:$ACCESS_PORT"

    # Generate SSH config for Remote-SSH
    SSH_CONFIG="$HOME/.ssh/config"
    mkdir -p "$HOME/.ssh"
    SSH_HOST_EXIST=$(grep -E "^Host code-server-$NAMESPACE$" "$SSH_CONFIG" 2>/dev/null || echo "")
    if [ -z "$SSH_HOST_EXIST" ]; then
        echo "" >> "$SSH_CONFIG"
        echo "# Added by code-server deployment script" >> "$SSH_CONFIG"
        echo "Host code-server-$NAMESPACE" >> "$SSH_CONFIG"
        echo "  HostName $ACCESS_IP" >> "$SSH_CONFIG"
        echo "  Port $ACCESS_PORT" >> "$SSH_CONFIG"
        echo "  User vscode" >> "$SSH_CONFIG"
        echo "  StrictHostKeyChecking no" >> "$SSH_CONFIG"
        log "SSH config added to $SSH_CONFIG for Host: code-server-$NAMESPACE"
    else
        log "SSH config for Host code-server-$NAMESPACE already exists"
    fi

    # Generate VS Code settings.json for remote development
    VSCODE_SETTINGS=".vscode/settings.json"
    mkdir -p ".vscode"
    SETTINGS_EXIST=$(grep "code-server-$NAMESPACE" "$VSCODE_SETTINGS" 2>/dev/null || echo "")
    if [ -z "$SETTINGS_EXIST" ]; then
        cat > "$VSCODE_SETTINGS" <<EOF
{
  "folders": [
    {
      "uri": "vscode-remote://ssh-remote+code-server-$NAMESPACE/home/coder/project"
    }
  ]
}
EOF
        log "VS Code settings.json generated with remote folders for code-server-$NAMESPACE"
    else
        log "VS Code settings already configured for code-server-$NAMESPACE"
    fi

    # Remote-Tunnels setup instructions
    echo ""
    echo "=== Remote-Tunnels Setup Instructions ==="
    echo "1. Ensure VS Code Remote Tunnels extension is installed"
    echo "2. In the pod, run: code tunnel --accept-server-license-terms"
    echo "3. Get the tunnel URL from output"
    echo "4. Configure Remote-Tunnels connection in VS Code"
    echo ""

else
    log "ERROR: Unknown service type: $SERVICE_TYPE_DETECTED"
    exit 1
fi

# Common output
echo ""
echo "=== VS Code Access Summary ==="
echo "Service Type: $SERVICE_TYPE_DETECTED"
echo "Namespace: $NAMESPACE"
echo "Access URL: $ACCESS_URL"
if [ "$SERVICE_TYPE_DETECTED" = "ClusterIP" ]; then
    echo "Port-Forward PID: $PORT_FORWARD_PID"
fi
echo ""
log "VS Code access wizard complete"

# Start spot pricing monitoring
if [ -n "$SERVER_CLASS" ]; then
  monitor_spot_pricing "$REGION" "$SERVER_CLASS" &
  log "Spot pricing monitoring started in background."
fi

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
fi