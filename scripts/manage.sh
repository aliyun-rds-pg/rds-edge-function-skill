#!/usr/bin/env bash

# RDS Edge Function Management Script
# CRUD only — to invoke a deployed function, use ./invoke.sh

set -euo pipefail

: "${SUPABASE_URL:?must be set, e.g. export SUPABASE_URL=http://<ip>}"
API_BASE="$SUPABASE_URL"
ANON_KEY="${SUPABASE_ANON_KEY:-}"
MANAGE_URL="${API_BASE%/}/functions/v1/manage"

# Auth args as a plain bash 3.2-compatible array.
AUTH_ARGS=(-s)
if [[ -n "$ANON_KEY" ]]; then
    AUTH_ARGS+=(-H "Authorization: Bearer ${ANON_KEY}")
fi

pretty() {
    python3 -m json.tool 2>/dev/null || cat
}

cmd_list() {
    curl "${AUTH_ARGS[@]}" -X GET "${MANAGE_URL}" | pretty
}

cmd_get() {
    curl "${AUTH_ARGS[@]}" -X GET "${MANAGE_URL}/$1" | pretty
}

cmd_delete() {
    curl "${AUTH_ARGS[@]}" -X DELETE "${MANAGE_URL}/$1" | pretty
}

cmd_delete_all() {
    curl "${AUTH_ARGS[@]}" -X DELETE "${MANAGE_URL}" | pretty
}

cmd_body() {
    # Raw multipart body — do not pretty-print.
    curl "${AUTH_ARGS[@]}" -X GET "${MANAGE_URL}/$1/body"
}

cmd_update() {
    local slug="$1" body="$2"
    curl "${AUTH_ARGS[@]}" -X PATCH "${MANAGE_URL}/${slug}" \
        -H "Content-Type: application/json" \
        -d "${body}" | pretty
}

cmd_ensure() {
    curl "${AUTH_ARGS[@]}" -X POST "${MANAGE_URL}/$1/_ensure" | pretty
}

cmd_redeploy_all() {
    curl "${AUTH_ARGS[@]}" -X POST "${MANAGE_URL}/_redeploy_all" | pretty
}

cmd_redeploy_status() {
    curl "${AUTH_ARGS[@]}" -X GET "${MANAGE_URL}/_redeploy_all/status" | pretty
}

usage() {
    cat <<EOF
Usage: $0 <command> [args]

Commands:
  list                          List all Edge Functions
  get <slug>                    Get function details
  delete <slug>                 Delete a function
  delete-all                    Delete all functions
  body <slug>                   Get function source (multipart/form-data)
  update <slug> <json>          PATCH function fields, e.g. '{"verify_jwt":false}'
  ensure <slug>                 Wake up / warm a function's sandbox
  redeploy-all                  Trigger async batch redeploy of every function
  redeploy-status               Poll batch redeploy progress

To invoke a deployed function, see ./invoke.sh.

Environment:
  SUPABASE_URL   Management API base (required)
  SUPABASE_ANON_KEY       Bearer token for management endpoints
EOF
}

require_arg() {
    # $1 = arg name shown in error, $2 = value
    if [[ -z "${2:-}" ]]; then
        echo "Error: $1 required" >&2
        usage >&2
        exit 1
    fi
    return 0
}

COMMAND="${1:-}"
case "$COMMAND" in
    list)             cmd_list ;;
    get)              require_arg slug "${2:-}"; cmd_get "$2" ;;
    delete)           require_arg slug "${2:-}"; cmd_delete "$2" ;;
    delete-all)       cmd_delete_all ;;
    body)             require_arg slug "${2:-}"; cmd_body "$2" ;;
    update)           require_arg slug "${2:-}"; require_arg json "${3:-}"; cmd_update "$2" "$3" ;;
    ensure)           require_arg slug "${2:-}"; cmd_ensure "$2" ;;
    redeploy-all)     cmd_redeploy_all ;;
    redeploy-status)  cmd_redeploy_status ;;
    -h|--help)        usage; exit 0 ;;
    "")               usage >&2; exit 1 ;;
    *)                echo "Error: Unknown command '${COMMAND}'" >&2; usage >&2; exit 1 ;;
esac
