#!/usr/bin/env bash
# OpenMetadata bootstrap for the platform: mint an automation token and create
# the scoped curation-agent bot. Everything the ingestion configs and the Phase 2
# agent need to authenticate.
#
#   scripts/openmetadata.sh wait            # block until the OM API answers
#   scripts/openmetadata.sh token [write]   # mint an admin PAT; `write` -> .env
#   scripts/openmetadata.sh bot   [write]   # create data-steward bot + RBAC; `write` -> .env
#
# Auth: logs in as the basic-auth admin. Override with OM_ADMIN_EMAIL /
# OM_ADMIN_PASSWORD (defaults admin@open-metadata.org / admin).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT/.env"
OM="${OPENMETADATA_URL:-http://localhost:8585}"
API="$OM/api/v1"
ADMIN_EMAIL="${OM_ADMIN_EMAIL:-admin@open-metadata.org}"
ADMIN_PW="${OM_ADMIN_PASSWORD:-admin}"

jqpy() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)"; }

login() {
  local b64; b64="$(printf '%s' "$ADMIN_PW" | base64)"
  curl -sf -X POST "$API/users/login" -H 'Content-Type: application/json' \
    -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$b64\"}" | jqpy 'd["accessToken"]'
}

# Upsert KEY=VALUE into .env (value may contain '='; only the first '=' splits).
set_env() {
  local key="$1" val="$2"
  touch "$ENV_FILE"
  if grep -q "^${key}=" "$ENV_FILE"; then
    grep -v "^${key}=" "$ENV_FILE" > "$ENV_FILE.tmp" && mv "$ENV_FILE.tmp" "$ENV_FILE"
  fi
  printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
  echo "  wrote $key to .env"
}

cmd_wait() {
  echo "waiting for OpenMetadata at $OM ..."
  for _ in $(seq 1 90); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$API/system/version" || echo 000)" = 200 ] \
      && { echo "OpenMetadata is up."; return 0; }
    sleep 4
  done
  echo "timed out waiting for OpenMetadata" >&2; return 1
}

cmd_token() {
  local at token; at="$(login)"
  token="$(curl -sf -X PUT "$API/users/security/token" \
    -H "Authorization: Bearer $at" -H 'Content-Type: application/json' \
    -d '{"tokenName":"phase1-automation","JWTTokenExpiry":"Unlimited"}' | jqpy 'd["jwtToken"]')"
  if [ "${1:-}" = write ]; then set_env OPENMETADATA_JWT_TOKEN "$token"; else echo "$token"; fi
}

cmd_bot() {
  local at role_id token uid; at="$(login)"
  local H=(-H "Authorization: Bearer $at" -H 'Content-Type: application/json')

  # Idempotency: a bot user can't be re-PUT once linked to a bot ("already used
  # by bot"), so delete an existing bot + its user first, then recreate. This
  # rotates the token on every run — the fresh one is what gets written to .env.
  curl -s -X DELETE "$API/bots/name/data-steward-bot?hardDelete=true" "${H[@]}" >/dev/null 2>&1 || true
  uid="$(curl -s "$API/users/name/data-steward-bot" "${H[@]}" | jqpy 'd.get("id","")' 2>/dev/null || true)"
  [ -n "$uid" ] && curl -s -X DELETE "$API/users/$uid?hardDelete=true" "${H[@]}" >/dev/null 2>&1 || true

  curl -sf -X PUT "$API/policies" "${H[@]}" -d '{
    "name":"data-steward-policy",
    "description":"Curation agent: read tables/schemas; edit glossary, tags and descriptions.",
    "rules":[{"name":"curate","effect":"allow",
      "resources":["glossary","glossaryTerm","tag","classification","table","databaseSchema","database"],
      "operations":["ViewAll","Create","EditDescription","EditTags","EditGlossaryTerms","EditOwners"]}]
  }' >/dev/null
  curl -sf -X PUT "$API/roles" "${H[@]}" \
    -d '{"name":"data-steward-role","description":"Curation agent role","policies":["data-steward-policy"]}' >/dev/null
  role_id="$(curl -sf "$API/roles/name/data-steward-role" "${H[@]}" | jqpy 'd["id"]')"

  # Creating a bot USER with an explicit JWT auth mechanism returns the token in
  # plaintext (the only reliable way to read a bot token programmatically here).
  token="$(curl -sf -X PUT "$API/users" "${H[@]}" -d "{
    \"name\":\"data-steward-bot\",\"email\":\"data-steward-bot@open-metadata.org\",\"isBot\":true,
    \"authenticationMechanism\":{\"authType\":\"JWT\",\"config\":{\"JWTTokenExpiry\":\"Unlimited\"}},
    \"roles\":[\"$role_id\"]
  }" | jqpy 'd["authenticationMechanism"]["config"]["JWTToken"]')"
  curl -sf -X PUT "$API/bots" "${H[@]}" \
    -d '{"name":"data-steward-bot","botUser":"data-steward-bot","description":"Curation agent (Phase 2), scoped by data-steward-role."}' >/dev/null

  echo "created policy=data-steward-policy role=data-steward-role bot=data-steward-bot"
  if [ "${1:-}" = write ]; then set_env OM_STEWARD_BOT_TOKEN "$token"; else echo "$token"; fi
}

case "${1:-}" in
  wait)  cmd_wait ;;
  token) cmd_token "${2:-}" ;;
  bot)   cmd_bot   "${2:-}" ;;
  *) echo "usage: $0 {wait|token [write]|bot [write]}" >&2; exit 2 ;;
esac
