#!/usr/bin/env bash
set -euo pipefail

# Helper functions for interacting with Rackspace Spot API
: "${SPOT_API_BASE:=https://spot.rackspace.com/api/v1}"
TOKEN_CACHE="${XDG_RUNTIME_DIR:-/tmp}/spot_token.json"

log() { if [ "${DEBUG:-0}" -eq 1 ]; then printf "%s %s\n" "$(date -Is)" "$*" >&2; fi; }

# get_spot_token: returns a bearer token (prints token)
get_spot_token() {
  if [ -n "${SPOT_API_TOKEN:-}" ]; then
    echo "${SPOT_API_TOKEN}"
    return 0
  fi

  # Try to reuse cached token if still valid
  if [ -f "${TOKEN_CACHE}" ]; then
    exp=$(jq -r '.expiry // empty' "${TOKEN_CACHE}" 2>/dev/null || echo "")
    token=$(jq -r '.token // empty' "${TOKEN_CACHE}" 2>/dev/null || echo "")
    if [ -n "$token" ] && [ -n "$exp" ]; then
      now=$(date +%s)
      if [ "$now" -lt "$exp" ]; then
        log "Using cached token (expires at $exp)"
        echo "$token"
        return 0
      fi
    fi
  fi

  if [ -n "${SPOT_CLIENT_ID:-}" ] && [ -n "${SPOT_CLIENT_SECRET:-}" ]; then
    log "Fetching token via client_credentials"
    resp=$(curl -s -X POST "${SPOT_API_BASE%/}/oauth/token"       -H "Content-Type: application/json"       -d "{"grant_type":"client_credentials","client_id":"${SPOT_CLIENT_ID}","client_secret":"${SPOT_CLIENT_SECRET}"}")
    token=$(echo "$resp" | jq -r '.access_token // .id_token // empty')
    expires_in=$(echo "$resp" | jq -r '.expires_in // 3600')
    if [ -z "$token" ]; then
      echo "Failed to obtain token from ${SPOT_API_BASE%/}/oauth/token, response: $resp" >&2
      return 1
    fi
    exp=$(( $(date +%s) + (expires_in - 30) ))
    jq -n --arg t "$token" --argjson e "$exp" '{token:$t, expiry:$e}' > "${TOKEN_CACHE}"
    echo "$token"
    return 0
  fi

  echo "ERROR: Must set SPOT_API_TOKEN or SPOT_CLIENT_ID+SPOT_CLIENT_SECRET" >&2
  return 1
}

# api_call <method> <path> [data]
# returns body and sets HTTP_STATUS global
api_call() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local token
  token=$(get_spot_token) || return 1
  local url="${SPOT_API_BASE%/}${path}"
  log "API CALL: ${method} ${url}"
  if [ -n "$data" ]; then
    resp=$(curl -s -w "\n%{http_code}" -X "$method" -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" "${url}" --data "$data")
  else
    resp=$(curl -s -w "\n%{http_code}" -X "$method" -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" "${url}")
  fi
  HTTP_STATUS=$(echo "$resp" | tail -n1)
  HTTP_BODY=$(echo "$resp" | sed '$d')
  if [ "$HTTP_STATUS" -lt 200 ] || [ "$HTTP_STATUS" -ge 300 ]; then
    log "API ERROR ${HTTP_STATUS}: $HTTP_BODY"
    return 1
  fi
  echo "$HTTP_BODY"
  return 0
}
