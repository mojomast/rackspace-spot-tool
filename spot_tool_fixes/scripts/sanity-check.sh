#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

if [ -z "${SPOT_ORG_NAMESPACE:-}" ]; then
  echo "Please set SPOT_ORG_NAMESPACE" >&2
  exit 1
fi

echo "Checking API connectivity..."
api_call GET /regions >/dev/null || { echo "Failed to GET /regions"; exit 1; }
echo "Regions OK"

echo "Checking organization access..."
api_call GET "/organizations/${SPOT_ORG_NAMESPACE}" >/dev/null || { echo "Failed to GET organization ${SPOT_ORG_NAMESPACE}"; exit 1; }
echo "Organization OK"

if command -v kubectl >/dev/null 2>&1; then
  echo "Checking Kubernetes cluster access (kubectl)..."
  kubectl get nodes || echo "kubectl failed or no kubeconfig present"
fi

echo "Sanity checks passed."
