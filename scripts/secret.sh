#!/usr/bin/env bash

# RDS Edge Function Secret Management Script
#
# Commands:
#   list                        List all secrets (values are SHA-256 masked)
#   set <name> <value>          Upsert a single secret (POST)
#   set-json <json-array>       Batch upsert (POST): '[{"name":"K","value":"V"}, ...]'
#   update <name> <value>       Update-only (PUT) — fails if name does not exist
#   update-json <json-array>    Batch update-only (PUT)
#   delete <name>               Delete a single secret
#   delete-batch <json-array>   Batch delete: '["K1","K2"]'

set -euo pipefail

: "${SUPABASE_URL:?must be set, e.g. export SUPABASE_URL=http://<ip>}"
API_BASE="$SUPABASE_URL"
ANON_KEY="${SUPABASE_ANON_KEY:-}"
SECRETS_URL="${API_BASE%/}/secrets/v1"

AUTH_ARGS=(-s)
if [[ -n "$ANON_KEY" ]]; then
    AUTH_ARGS+=(-H "Authorization: Bearer ${ANON_KEY}")
fi

pretty() {
    python3 -m json.tool 2>/dev/null || cat
}

# Encode a {name, value} pair into a one-element JSON array.
# Uses python3 so quotes/backslashes/newlines in `value` are escaped correctly.
json_kv() {
    python3 -c '
import json, sys
name, value = sys.argv[1], sys.argv[2]
print(json.dumps([{"name": name, "value": value}]))
' "$1" "$2"
}

cmd_list() {
    echo "Listing all secrets..." >&2
    curl "${AUTH_ARGS[@]}" -X GET "${SECRETS_URL}" | pretty
}

cmd_post() {
    # POST = upsert
    local body="$1"
    curl "${AUTH_ARGS[@]}" -X POST "${SECRETS_URL}" \
        -H "Content-Type: application/json" \
        -d "${body}" | pretty
}

cmd_put() {
    # PUT = update only
    local body="$1"
    curl "${AUTH_ARGS[@]}" -X PUT "${SECRETS_URL}" \
        -H "Content-Type: application/json" \
        -d "${body}" | pretty
}

cmd_delete_one() {
    local name="$1"
    echo "Deleting secret: ${name}" >&2
    curl "${AUTH_ARGS[@]}" -X DELETE "${SECRETS_URL}/${name}" | pretty
}

cmd_delete_batch() {
    local body="$1"
    echo "Batch deleting secrets..." >&2
    curl "${AUTH_ARGS[@]}" -X DELETE "${SECRETS_URL}" \
        -H "Content-Type: application/json" \
        -d "${body}" | pretty
}

usage() {
    cat <<'EOF'
Usage: secret.sh <command> [args]

Commands:
  list                        List all secrets (values are SHA-256 masked)
  set <name> <value>          Upsert a single secret (POST)
  set-json '<json-array>'     Batch upsert: '[{"name":"K","value":"V"}, ...]'
  update <name> <value>       Update-only (PUT); fails if name does not exist
  update-json '<json-array>'  Batch update-only
  delete <name>               Delete a single secret
  delete-batch '<json-array>' Batch delete: '["K1","K2"]'

Environment:
  SUPABASE_URL   Management API base
  SUPABASE_ANON_KEY       Bearer token

Note: a function must be redeployed to pick up changed secrets.
EOF
}

require_arg() {
    if [[ -z "${2:-}" ]]; then
        echo "Error: $1 required" >&2
        usage >&2
        exit 1
    fi
    return 0
}

COMMAND="${1:-}"
case "$COMMAND" in
    list)
        cmd_list ;;
    set)
        require_arg name "${2:-}"; require_arg value "${3:-}"
        echo "Setting secret: $2" >&2
        cmd_post "$(json_kv "$2" "$3")" ;;
    set-json)
        require_arg "json array" "${2:-}"
        echo "Batch setting secrets..." >&2
        cmd_post "$2" ;;
    update)
        require_arg name "${2:-}"; require_arg value "${3:-}"
        echo "Updating secret: $2" >&2
        cmd_put "$(json_kv "$2" "$3")" ;;
    update-json)
        require_arg "json array" "${2:-}"
        echo "Batch updating secrets..." >&2
        cmd_put "$2" ;;
    delete)
        require_arg name "${2:-}"
        cmd_delete_one "$2" ;;
    delete-batch)
        require_arg "json array" "${2:-}"
        cmd_delete_batch "$2" ;;
    -h|--help)
        usage; exit 0 ;;
    "")
        usage >&2; exit 1 ;;
    *)
        echo "Error: Unknown command '${COMMAND}'" >&2; usage >&2; exit 1 ;;
esac
