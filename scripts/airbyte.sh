#!/usr/bin/env bash
# Thin wrapper over the Airbyte public API for the things Terraform does not do:
# minting a token, triggering an ad-hoc sync, and reading the catalog/connector
# versions you need in order to *write* the Terraform.
#
#   scripts/airbyte.sh creds      # refresh AIRBYTE_* values in .env
#   scripts/airbyte.sh sync       # trigger a sync and follow it to completion
#   scripts/airbyte.sh streams    # list the source's stream names
#   scripts/airbyte.sh versions   # connector versions this install runs
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT/.env"
TF_DIR="$ROOT/ingestion/terraform"

AIRBYTE_URL="${AIRBYTE_URL:-http://localhost:8000}"
API="$AIRBYTE_URL/api/public/v1"

# abctl decorates its output with ANSI colour; strip it before capturing values.
abctl_field() {
  abctl local credentials 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*m//g' \
    | grep -oP "$1:\s*\K\S+"
}

token() {
  local cid csec
  cid="${AIRBYTE_CLIENT_ID:-$(abctl_field Client-Id)}"
  csec="${AIRBYTE_CLIENT_SECRET:-$(abctl_field Client-Secret)}"
  curl -sf -X POST "$API/applications/token" \
    -H 'Content-Type: application/json' \
    -d "{\"client_id\":\"$cid\",\"client_secret\":\"$csec\"}" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])'
}

cmd_creds() {
  local cid csec ws tmp
  cid="$(abctl_field Client-Id)"
  csec="$(abctl_field Client-Secret)"
  ws="$(AIRBYTE_CLIENT_ID="$cid" AIRBYTE_CLIENT_SECRET="$csec" bash -c '
    set -e
    t=$(curl -sf -X POST "'"$API"'/applications/token" -H "Content-Type: application/json" \
      -d "{\"client_id\":\"$AIRBYTE_CLIENT_ID\",\"client_secret\":\"$AIRBYTE_CLIENT_SECRET\"}" \
      | python3 -c "import sys,json;print(json.load(sys.stdin)[\"access_token\"])")
    curl -sf "'"$API"'/workspaces" -H "Authorization: Bearer $t" \
      | python3 -c "import sys,json;print(json.load(sys.stdin)[\"data\"][0][\"workspaceId\"])"
  ')"

  tmp="$(mktemp)"
  # Rewrite rather than append, so re-running after `abctl local uninstall`
  # replaces stale credentials instead of stacking duplicate keys.
  grep -vE '^(AIRBYTE_CLIENT_ID|AIRBYTE_CLIENT_SECRET|AIRBYTE_WORKSPACE_ID)=' "$ENV_FILE" 2>/dev/null > "$tmp" || true
  {
    echo "AIRBYTE_CLIENT_ID=$cid"
    echo "AIRBYTE_CLIENT_SECRET=$csec"
    echo "AIRBYTE_WORKSPACE_ID=$ws"
  } >> "$tmp"
  mv "$tmp" "$ENV_FILE"
  echo "Wrote AIRBYTE_CLIENT_ID / AIRBYTE_CLIENT_SECRET / AIRBYTE_WORKSPACE_ID to .env"
  echo "  workspace: $ws"
}

cmd_sync() {
  local t conn job status
  t="$(token)"
  conn="$(terraform -chdir="$TF_DIR" output -raw connection_id)"
  job="$(curl -sf -X POST "$API/jobs" -H "Authorization: Bearer $t" \
    -H 'Content-Type: application/json' \
    -d "{\"connectionId\":\"$conn\",\"jobType\":\"sync\"}" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["jobId"])')"
  echo "sync job $job started"

  while true; do
    status="$(curl -sf "$API/jobs/$job" -H "Authorization: Bearer $t" \
      | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["status"],d.get("rowsSynced",0),d.get("duration",""))')"
    echo "  $status"
    case "$status" in
      succeeded*) return 0 ;;
      failed*|cancelled*|incomplete*) return 1 ;;
    esac
    sleep 10
  done
}

cmd_streams() {
  local t src
  t="$(token)"
  src="$(terraform -chdir="$TF_DIR" output -raw source_id)"
  # discover_schema is only on the config API; the public API has no equivalent.
  curl -sf -X POST "$AIRBYTE_URL/api/v1/sources/discover_schema" \
    -H "Authorization: Bearer $t" -H 'Content-Type: application/json' \
    -d "{\"sourceId\":\"$src\",\"disable_cache\":true}" \
    | python3 -c '
import json, sys
for s in json.load(sys.stdin)["catalog"]["streams"]:
    st = s["stream"]
    modes = ",".join(st.get("supportedSyncModes", []))
    cursor = ".".join(st.get("defaultCursorField") or []) or "-"
    print("{:<34} {:<28} cursor={}".format(st["name"], modes, cursor))
'
}

cmd_versions() {
  local t
  t="$(token)"
  for kind in source destination; do
    curl -sf -X POST "$AIRBYTE_URL/api/v1/${kind}_definitions/list" \
      -H "Authorization: Bearer $t" -H 'Content-Type: application/json' -d '{}' \
      | python3 -c "
import json,sys
kind = '${kind}'
# Only the two connectors this project pins in ingestion/terraform/.
wanted = {'source': 'stripe', 'destination': 'postgres'}[kind]
for d in json.load(sys.stdin)[kind + 'Definitions']:
    if d['name'].lower() == wanted:
        print('{:<12} {:<10} {:<10} {}'.format(kind, d['name'], d['dockerImageTag'], d[kind + 'DefinitionId']))
"
  done
}

case "${1:-}" in
  creds)    cmd_creds ;;
  sync)     cmd_sync ;;
  streams)  cmd_streams ;;
  versions) cmd_versions ;;
  *) echo "usage: $0 {creds|sync|streams|versions}" >&2; exit 2 ;;
esac
