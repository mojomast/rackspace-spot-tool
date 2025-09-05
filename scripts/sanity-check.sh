#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

# Parse arguments
DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--dry-run]"
      echo "Performs sanity checks on Rackspace Spot API and Kubernetes connectivity"
      echo "--dry-run    Show what checks would be performed without making API calls"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Use --help for usage information" >&2
      exit 1
      ;;
  esac
done

if [ -z "${SPOT_ORG_NAMESPACE:-}" ]; then
  echo "❌ ERROR: SPOT_ORG_NAMESPACE environment variable is required" >&2
  exit 1
fi

if $DRY_RUN; then
  echo "🔍 DRY RUN MODE - Simulating sanity checks:"
  echo "  ✓ Would validate SPOT_ORG_NAMESPACE: ${SPOT_ORG_NAMESPACE}"
  echo "  ✓ Would check API connectivity to /regions"
  echo "  ✓ Would check organization access to /organizations/${SPOT_ORG_NAMESPACE}/cloudspaces"
  echo "  ✓ Would verify Kubernetes cluster access via kubectl get nodes (if available)"
  echo "✅ Dry run completed - no API calls made"
  exit 0
fi

echo "🔍 Starting sanity checks..."

# Check 1: GET /regions (expect >= 1)
echo "Checking API connectivity and available regions..."
if regions_json=$(api_call GET /regions 2>/dev/null); then
  regions_count=$(echo "$regions_json" | jq '. | length' 2>/dev/null || echo "0")
  if [ "$regions_count" -ge 1 ]; then
    echo "✅ Regions OK - Found $regions_count region(s)"
    log "Available regions: $(echo "$regions_json" | jq -r '.[]?.name // .[]?.code // empty' 2>/dev/null || echo 'unknown')"
  else
    echo "❌ ERROR: Unexpected response from /regions - no regions found or invalid JSON" >&2
    exit 1
  fi
else
  echo "❌ ERROR: Failed to connect to Rackspace Spot API or get regions" >&2
  exit 1
fi

# Check 2: GET /organizations/${SPOT_ORG_NAMESPACE}/cloudspaces (expect success)
echo "Checking organization cloudspace access..."
if cloudspaces_json=$(api_call GET "/organizations/${SPOT_ORG_NAMESPACE}/cloudspaces" 2>/dev/null); then
  cloudspaces_count=$(echo "$cloudspaces_json" | jq '. | length' 2>/dev/null || echo "0")
  echo "✅ Cloudspaces OK - Found $cloudspaces_count cloudspace(s) for organization ${SPOT_ORG_NAMESPACE}"
else
  echo "❌ ERROR: Failed to access cloudspaces for organization ${SPOT_ORG_NAMESPACE}" >&2
  echo "   → Verify SPOT_ORG_NAMESPACE is correct and your token has access to this organization" >&2
  exit 1
fi

# Check 3: kubectl get nodes (if kubeconfig present)
if command -v kubectl >/dev/null 2>&1; then
  echo "Checking Kubernetes cluster connectivity..."
  if kubectl get nodes --request-timeout=10s >/dev/null 2>&1; then
    nodes_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    echo "✅ Kubernetes OK - Cluster accessible with $nodes_count node(s)"
  else
    echo "⚠️  WARNING: kubectl command failed - Kubernetes cluster not accessible or kubeconfig missing"
    echo "   → Ensure kubectl is configured and pointing to the correct cluster"
  fi
else
  echo "ℹ️  kubectl not found - skipping Kubernetes cluster check"
fi

echo "🎉 All sanity checks passed successfully!"
