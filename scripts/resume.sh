#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

usage() {
  cat <<EOF
Usage: $0 --nodepool-id ID --count N
This script scales a Spot nodepool to N (resume). Requires SPOT_ORG_NAMESPACE.
EOF
  exit 1
}

if [ "$#" -ne 4 ]; then usage; fi
if [ "$1" != "--nodepool-id" ]; then usage; fi
NODEPOOL_ID="$2"
if [ "$3" != "--count" ]; then usage; fi
COUNT="$4"

echo "Resuming nodepool ${NODEPOOL_ID} to ${COUNT}..."
payload=$(jq -n --argjson c "$COUNT" '{desired:$c}')
api_call POST "/organizations/${SPOT_ORG_NAMESPACE}/nodepools/${NODEPOOL_ID}/scale" "$payload" || { echo "Failed to scale nodepool"; exit 1; }
echo "Scale request submitted; wait for nodes to join."
