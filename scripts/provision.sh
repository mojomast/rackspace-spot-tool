#!/usr/bin/env bash
set -euo pipefail

# Provision script: select region and serverclass and create a cloudspace/nodepool
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

usage() {
  cat <<EOF
Usage: $0 [--region REGION] [--dry-run] [--output json|table|short] [--metric cpu+mem|cpu-only]
ENV via .env or environment variables:
  SPOT_API_BASE, SPOT_API_TOKEN, SPOT_CLIENT_ID, SPOT_CLIENT_SECRET, SPOT_ORG_NAMESPACE
EOF
  exit 1
}

REGION=""
DRY_RUN=0
OUTPUT="table"
METRIC="cpu+mem"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    --output) OUTPUT="$2"; shift 2;;
    --metric) METRIC="$2"; shift 2;;
    --debug) DEBUG=1; shift;;
    -h|--help) usage;;
    *) echo "Unknown arg: $1"; usage;;
  esac
done

# ensure org namespace present
if [ -z "${SPOT_ORG_NAMESPACE:-}" ]; then
  echo "Please set SPOT_ORG_NAMESPACE environment variable" >&2
  exit 1
fi

# fetch regions dynamically
regions_json=$(api_call GET /regions) || { echo "Failed to list regions"; exit 1; }
regions=$(echo "$regions_json" | jq -r '.[]?.name')

if [ -z "$REGION" ]; then
  echo "Available regions:"
  echo "$regions" | nl -ba
  read -rp "Select region (name): " REGION
fi

if ! echo "$regions" | grep -qx "$REGION"; then
  echo "Invalid region: $REGION" >&2
  exit 1
fi

# fetch serverclasses in region
serverclasses_json=$(api_call GET "/serverclasses?region=${REGION}") || { echo "Failed to list serverclasses"; exit 1; }

# compute score for each serverclass
VCPU_WEIGHT="${VCPU_WEIGHT:-1.0}"
MEM_WEIGHT="${MEM_WEIGHT:-0.5}"
GPU_WEIGHT="${GPU_WEIGHT:-4.0}"

# build a temporary JSON array with computed score
ranked=$(echo "$serverclasses_json" | jq -r --arg vwc "$VCPU_WEIGHT" --arg mwc "$MEM_WEIGHT" --arg gwc "$GPU_WEIGHT" '
  map({
    id: .id,
    name: .name,
    vcpu: (.vcpu // .vCPU // 0),
    memory_gb: (.memory_gb // .memoryGB // 0),
    price_hour: (.price_hour // .price_per_hour // 0),
    gpus: (.gpus // 0)
  }) | map(. + {score: ( (.price_hour) / ( ($vwc|tonumber)*(.vcpu) + ($mwc|tonumber)*(.memory_gb) + ($gwc|tonumber)*(.gpus) ) }) ) | sort_by(.score)
')

# pick top candidate
candidate=$(echo "$ranked" | jq -r '.[0]')

if [ -z "$candidate" ] || [ "$candidate" = "null" ]; then
  echo "No serverclass candidates found for region ${REGION}" >&2
  exit 1
fi

if [ "$OUTPUT" = "json" ]; then
  echo "$candidate" | jq .
else
  echo "Chosen candidate:"
  echo "$candidate" | jq -r '"Name: \(.name) | vCPU: \(.vcpu) | Memory(GB): \(.memory_gb) | Price/hr: \(.price_hour) | Score: \(.score)"'
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "Dry run mode; not creating resources."
  exit 0
fi

# Create cloudspace under organization
create_payload=$(jq -n --arg name "spot-cloudspace-$(date +%s)" --arg region "$REGION" --arg serverclass "$(echo "$candidate" | jq -r '.id')"   '{name:$name, region:$region, server_class:$serverclass}')

echo "Creating cloudspace under organization ${SPOT_ORG_NAMESPACE}..."
created=$(api_call POST "/organizations/${SPOT_ORG_NAMESPACE}/cloudspaces" "$create_payload") || { echo "Cloudspace creation failed"; exit 1; }
cloudspace_id=$(echo "$created" | jq -r '.id // .cloudspace_id // empty')
echo "Created cloudspace: $cloudspace_id"
