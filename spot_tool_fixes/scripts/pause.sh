#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

usage() {
  cat <<EOF
Usage: $0 --nodepool-id ID
This script scales a Spot nodepool to 0 (pause). Requires SPOT_ORG_NAMESPACE.
EOF
  exit 1
}

if [ $# -lt 2 ]; then usage; fi
if [ "$1" != "--nodepool-id" ]; then usage; fi
NODEPOOL_ID="$2"

echo "Pausing nodepool ${NODEPOOL_ID}..."
payload='{"desired":0}'
api_call POST "/organizations/${SPOT_ORG_NAMESPACE}/nodepools/${NODEPOOL_ID}/scale" "$payload" || { echo "Failed to scale nodepool"; exit 1; }
echo "Requested scale to 0; verify with API."
