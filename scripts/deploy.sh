#!/usr/bin/env bash

# RDS Edge Function Deploy Script
# Usage: ./deploy.sh <path|--url URL> [options]
#
# Modes:
#   1. Folder:  ./deploy.sh ./my-function -s my-func -e index.ts
#   2. Zip:     ./deploy.sh ./code.zip -s my-func -e index.ts
#   3. URL:     ./deploy.sh --url https://example.com/code.zip -s my-func

set -euo pipefail

# ─── Config ───────────────────────────────────────────────────
: "${SUPABASE_URL:?must be set, e.g. export SUPABASE_URL=http://<ip>}"
API_BASE="$SUPABASE_URL"
ANON_KEY="${SUPABASE_ANON_KEY:-}"
DEPLOY_ENDPOINT="${API_BASE%/}/functions/v1/manage/deploy"
ENSURE_BASE="${API_BASE%/}/functions/v1/manage"

# ─── Defaults ─────────────────────────────────────────────────
INPUT_PATH=""
DOWNLOAD_URL=""
SLUG=""
ENTRYPOINT=""
COMMAND=""
VERIFY_JWT="true"
DO_INVOKE=false

# ─── Parse Arguments ─────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --url)         DOWNLOAD_URL="$2"; shift 2 ;;
        -s|--slug)     SLUG="$2"; shift 2 ;;
        -e|--entrypoint) ENTRYPOINT="$2"; shift 2 ;;
        -c|--command)  COMMAND="$2"; shift 2 ;;
        --no-jwt)      VERIFY_JWT="false"; shift ;;
        --invoke)      DO_INVOKE=true; shift ;;
        -h|--help)
            cat <<EOF
Usage: $0 <path|--url URL> [options]

Arguments:
  <path>                  Folder or .zip file to deploy
  --url <URL>             Download URL for code zip

Options:
  -s, --slug <slug>       Function slug (default: folder/zip basename, lowercased)
  -e, --entrypoint <file> Entry file (e.g. index.ts)
  -c, --command <cmd>     Custom start command (overrides entrypoint-derived deno run)
  --no-jwt                Disable JWT verification (function is public)
  --invoke                Warm sandbox via /_ensure and POST a smoke test
  -h, --help              Show this help

Environment:
  SUPABASE_URL   Management & invoke base (required)
  SUPABASE_ANON_KEY       Bearer for both management and invoke

Conventions:
  - Function code MUST start an HTTP server on port 8000.
  - Without -c, command is: deno run --allow-net --allow-env /code/<entrypoint>
EOF
            exit 0 ;;
        -*)            echo "Error: Unknown option: $1" >&2; exit 1 ;;
        *)             INPUT_PATH="$1"; shift ;;
    esac
done

# ─── Validation ──────────────────────────────────────────────
if [[ -z "$INPUT_PATH" && -z "$DOWNLOAD_URL" ]]; then
    echo "Error: Must provide a path (folder or .zip) or --url" >&2
    echo "Run '$0 --help' for usage." >&2
    exit 1
fi

# ─── Auth args ───────────────────────────────────────────────
# Use AUTH_OPT() expansion to avoid set -u bugs on empty arrays in bash 3.2.
AUTH_ARGS=()
if [[ -n "$ANON_KEY" ]]; then
    AUTH_ARGS=(-H "Authorization: Bearer ${ANON_KEY}")
fi

# ─── Build metadata JSON via python (handles quoting) ────────
build_metadata() {
    VERIFY_JWT="$VERIFY_JWT" SLUG="$SLUG" ENTRYPOINT="$ENTRYPOINT" \
    python3 -c '
import json, os
m = {"verify_jwt": os.environ["VERIFY_JWT"].lower() == "true"}
if os.environ.get("SLUG"): m["name"] = os.environ["SLUG"]
if os.environ.get("ENTRYPOINT"): m["entrypoint_path"] = os.environ["ENTRYPOINT"]
print(json.dumps(m))
'
}

# ─── Mode 1: URL Deploy ──────────────────────────────────────
deploy_via_url() {
    local url="$1"
    echo "Deploying via URL: ${url}" >&2

    local body
    body=$(URL="$url" COMMAND="$COMMAND" VERIFY_JWT="$VERIFY_JWT" SLUG="$SLUG" ENTRYPOINT="$ENTRYPOINT" \
        python3 -c '
import json, os
b = {"downloadUrl": os.environ["URL"]}
if os.environ.get("COMMAND"): b["command"] = os.environ["COMMAND"]
m = {"verify_jwt": os.environ["VERIFY_JWT"].lower() == "true"}
if os.environ.get("SLUG"): m["name"] = os.environ["SLUG"]
if os.environ.get("ENTRYPOINT"): m["entrypoint_path"] = os.environ["ENTRYPOINT"]
b["metadata"] = m
print(json.dumps(b))
')

    curl -s -X POST "${DEPLOY_ENDPOINT}?slug=${SLUG}" \
        ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} \
        -H "Content-Type: application/json" \
        -d "${body}"
}

# ─── Mode 2: Zip Deploy ──────────────────────────────────────
deploy_via_zip() {
    local zip_path="$1"
    local zip_name
    zip_name=$(basename "$zip_path")

    echo "Deploying via zip: ${zip_path}" >&2

    local metadata
    metadata=$(build_metadata)

    curl -s -X POST "${DEPLOY_ENDPOINT}?slug=${SLUG}" \
        ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} \
        -F "metadata=${metadata}" \
        -F "file=@${zip_path};filename=${zip_name}"
}

# ─── Mode 3: Folder Deploy ───────────────────────────────────
deploy_via_folder() {
    local folder_path="$1"
    folder_path=$(cd "$folder_path" && pwd)

    echo "Deploying from folder: ${folder_path}" >&2

    local file_args=()
    local file_count=0

    while IFS= read -r -d '' filepath; do
        local relpath="${filepath#${folder_path}/}"
        file_args+=(-F "file=@${filepath};filename=${relpath}")
        file_count=$((file_count + 1))
    done < <(find "$folder_path" -type f \
        ! -name '.*' \
        ! -name '*.zip' \
        ! -path '*/.git/*' \
        ! -path '*/node_modules/*' \
        ! -path '*/__pycache__/*' \
        -print0 | sort -z)

    if [[ $file_count -eq 0 ]]; then
        echo "Error: No files found in ${folder_path}" >&2
        exit 1
    fi

    echo "Found ${file_count} file(s) to upload" >&2

    local metadata
    metadata=$(build_metadata)

    curl -s -X POST "${DEPLOY_ENDPOINT}?slug=${SLUG}" \
        ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} \
        -F "metadata=${metadata}" \
        "${file_args[@]}"
}

# ─── Determine Mode & Slug ───────────────────────────────────
if [[ -n "$DOWNLOAD_URL" ]]; then
    if [[ -z "$SLUG" ]]; then
        echo "Error: --slug is required for URL deploy" >&2
        exit 1
    fi
    RESPONSE=$(deploy_via_url "$DOWNLOAD_URL")
elif [[ -n "$INPUT_PATH" ]]; then
    if [[ -z "$SLUG" ]]; then
        if [[ -d "$INPUT_PATH" ]]; then
            SLUG=$(basename "$(cd "$INPUT_PATH" && pwd)")
        else
            SLUG=$(basename "$INPUT_PATH" .zip)
        fi
        SLUG=$(echo "$SLUG" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g; s/^-//; s/-$//')
        echo "Auto-detected slug: ${SLUG}" >&2
    fi

    if [[ -f "$INPUT_PATH" && "$INPUT_PATH" == *.zip ]]; then
        RESPONSE=$(deploy_via_zip "$INPUT_PATH")
    elif [[ -d "$INPUT_PATH" ]]; then
        RESPONSE=$(deploy_via_folder "$INPUT_PATH")
    else
        echo "Error: '${INPUT_PATH}' is not a valid folder or .zip file" >&2
        exit 1
    fi
fi

# ─── Output Result ───────────────────────────────────────────
echo "" >&2

if echo "$RESPONSE" | grep -q '"code"'; then
    echo "Deploy FAILED:" >&2
    echo "$RESPONSE" | python3 -m json.tool 2>/dev/null >&2 || echo "$RESPONSE" >&2
    exit 1
fi

STATUS=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status','UNKNOWN'))" 2>/dev/null || echo "UNKNOWN")
VERSION=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('version','?'))" 2>/dev/null || echo "?")

echo "Deploy SUCCESS: slug=${SLUG}, status=${STATUS}, version=${VERSION}" >&2

# ─── Optional: Invoke ────────────────────────────────────────
if [[ "$DO_INVOKE" == true ]]; then
    echo "" >&2
    echo "Warming sandbox..." >&2
    curl -s -X POST "${ENSURE_BASE}/${SLUG}/_ensure" ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} >/dev/null || true

    INVOKE_URL="${API_BASE%/}/functions/v1/${SLUG}"

    INVOKE_ARGS=(-s -o /tmp/.rds_invoke.body -w "%{http_code}" -X POST "$INVOKE_URL" \
        -H "Content-Type: application/json" -d "{}")
    if [[ -n "$ANON_KEY" ]]; then
        INVOKE_ARGS+=(-H "Authorization: Bearer ${ANON_KEY}")
    fi

    echo "POST ${INVOKE_URL}" >&2

    # Retry briefly: Kong → sandbox bootstrap can take a moment.
    # Stop on first 2xx; otherwise sleep and retry.
    HTTP_CODE=""
    for attempt in 1 2 3 4 5 6; do
        HTTP_CODE=$(curl "${INVOKE_ARGS[@]}" 2>/dev/null || echo "000")
        if [[ "$HTTP_CODE" =~ ^2 ]]; then
            break
        fi
        sleep 1
    done

    echo "Invoke response (HTTP ${HTTP_CODE}):" >&2
    cat /tmp/.rds_invoke.body >&2 2>/dev/null || true
    echo >&2
    rm -f /tmp/.rds_invoke.body
fi

# Output deploy result JSON to stdout
echo "$RESPONSE"
