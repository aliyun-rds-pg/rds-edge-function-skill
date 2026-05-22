#!/usr/bin/env bash

# RDS Edge Function Invoke Script
# POST <SUPABASE_URL>/functions/v1/<slug>
#
# Usage:
#   invoke.sh <slug> [-d '<json>'] [-H 'Header: value']... [--no-auth] [--get]

set -euo pipefail

: "${SUPABASE_URL:?must be set, e.g. export SUPABASE_URL=http://<ip>}"
API_BASE="$SUPABASE_URL"
ANON_KEY="${SUPABASE_ANON_KEY:-}"

SLUG=""
DATA=""
METHOD="POST"
NO_AUTH=false
HEADERS=()

usage() {
    cat <<EOF
Usage: $0 <slug> [options]

Arguments:
  <slug>                  Function slug to invoke

Options:
  -d, --data <json>       Request body (JSON). If omitted, sends '{}'
  -H, --header <h>        Extra header (repeatable), e.g. -H 'X-Foo: bar'
  --get                   Use GET instead of POST (no body sent)
  --no-auth               Do not send Authorization header
  -h, --help              Show this help

Environment:
  SUPABASE_URL   Management & invoke base (required)
  SUPABASE_ANON_KEY       Bearer token sent for JWT-protected functions
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--data)      DATA="$2"; shift 2 ;;
        -H|--header)    HEADERS+=("-H" "$2"); shift 2 ;;
        --get)          METHOD="GET"; shift ;;
        --no-auth)      NO_AUTH=true; shift ;;
        -h|--help)      usage; exit 0 ;;
        -*)             echo "Error: Unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)
            if [[ -z "$SLUG" ]]; then SLUG="$1"; shift
            else echo "Error: Unexpected positional arg: $1" >&2; exit 1
            fi ;;
    esac
done

if [[ -z "$SLUG" ]]; then
    echo "Error: slug is required" >&2
    usage >&2
    exit 1
fi

URL="${API_BASE%/}/functions/v1/${SLUG}"
echo "${METHOD} ${URL}" >&2

CURL_ARGS=(-s -X "$METHOD" "$URL")
if [[ "$NO_AUTH" == false && -n "$ANON_KEY" ]]; then
    CURL_ARGS+=(-H "Authorization: Bearer ${ANON_KEY}")
fi
if [[ "$METHOD" == "POST" ]]; then
    [[ -z "$DATA" ]] && DATA="{}"
    CURL_ARGS+=(-H "Content-Type: application/json" -d "$DATA")
fi
CURL_ARGS+=("${HEADERS[@]+"${HEADERS[@]}"}")

curl "${CURL_ARGS[@]}"
