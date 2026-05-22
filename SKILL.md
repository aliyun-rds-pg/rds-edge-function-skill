---
name: rds-edge-function
description: Deploy, manage, invoke RDS Supabase Edge Functions, and manage their secrets. Use when the user wants to deploy an edge function, list/get/delete functions, invoke a function (call `functions/v1/<slug>`), or create/update/delete function secrets.
---

# RDS Edge Function

Operate an RDS Supabase–compatible Edge Function deployment from the shell:

| Script | Purpose |
|---|---|
| `scripts/deploy.sh` | Deploy a folder, zip, or remote URL as a function |
| `scripts/invoke.sh` | Call a deployed function (`POST /functions/v1/<slug>`) |
| `scripts/manage.sh` | List / get / delete / update / ensure / batch-redeploy |
| `scripts/secret.sh` | CRUD for function secrets (env vars) |

All scripts have `--help`. Read it before improvising flags.

## Requirements

`bash` (3.2+), `curl`, and `python3` must be available on `PATH`. `python3` is used internally for safe JSON encoding/decoding.

## Environment — preflight before running anything

**Before invoking any script in this skill, verify the env vars below are exported in the user's shell.** If either is missing, **STOP and tell the user clearly which one is unset** — do NOT run the script. Scripts exit immediately with a clear error if `SUPABASE_URL` is unset, but ill-set credentials still surface as opaque HTTP errors.

Point the user at the Edge Function console Skills page (`<console-origin>/skills` → section "Configure access credentials") — it renders a ready-to-paste `export` block already filled with the correct host and anon key for their instance.

Required for every operation in this skill:

| Var | Purpose |
|---|---|
| `SUPABASE_URL` | Base URL of the Edge Function management & invoke service. Format is always `http://<ip>` (port 80) |
| `SUPABASE_ANON_KEY` | Bearer token. Anon key is sufficient for `/functions/v1/manage/*`, `/secrets/v1*`, and JWT-protected invokes — service-role key is **not** needed and intentionally not used here |

Quick check (run once per session before the first script call):

```bash
[ -n "$SUPABASE_URL" ] || echo "SUPABASE_URL not set — copy the export block from the Edge Function console Skills page"
[ -n "$SUPABASE_ANON_KEY" ]     || echo "SUPABASE_ANON_KEY not set — same as above"
```

## Typical flows

**Deploy a folder and verify**

```bash
bash scripts/deploy.sh ./my-func -s my-func -e index.ts --invoke
```

`--invoke` calls `_ensure` to warm the sandbox, then retries the POST briefly to absorb the deploy→Kong propagation delay.

**Invoke an existing function**

```bash
bash scripts/invoke.sh my-func -d '{"name":"world"}'
bash scripts/invoke.sh my-func --get                  # GET, no body
bash scripts/invoke.sh my-func --no-auth              # for verify_jwt:false functions
```

**Inspect / manage**

```bash
bash scripts/manage.sh list
bash scripts/manage.sh get my-func
bash scripts/manage.sh update my-func '{"verify_jwt":false}'
bash scripts/manage.sh ensure my-func                 # wake / warm sandbox
bash scripts/manage.sh redeploy-all                   # async batch redeploy
bash scripts/manage.sh redeploy-status                # poll batch progress
bash scripts/manage.sh delete my-func
```

**Manage secrets** (a function must be **redeployed** to pick up changed values)

```bash
bash scripts/secret.sh set OPENAI_API_KEY sk-...
bash scripts/secret.sh list
bash scripts/secret.sh delete OPENAI_API_KEY
bash scripts/deploy.sh ./my-func -s my-func -e index.ts   # redeploy to apply
```

## Conventions

- Function code MUST start an HTTP server listening on **port 8000** — without it Kong returns "Connection refused". Pure scripts (e.g. only `console.log`) will fail.
- `slug` defaults to the lowercased folder/zip basename when omitted; pass `-s` to override.
- Without `-c`/`--command`, the start command is `deno run --allow-net --allow-env /code/<entrypoint>`. Pass `-c` for non-Deno runtimes.
- Folder deploy excludes hidden files (`.*`), `*.zip`, `.git/`, `node_modules/`, `__pycache__/`. If your function relies on a hidden file (e.g. `.env`), inline it instead.
- Deploy/invoke parameters mirror the Supabase community API. Custom extensions (`downloadUrl`, `command`) live in the JSON body of `POST /functions/v1/manage/deploy`.

## When to consult `references/api.md`

Read it when you need any of:

- The full request/response shape of a management endpoint
- Error code semantics (`E2B_NOT_ENABLED`, `CODE_CHECK_FAILED`, `REDEPLOY_IN_PROGRESS`, ...)
- Multipart `metadata` schema (`entrypoint_path`, `static_patterns`, `verify_jwt`, ...)
- Behavior of the batch redeploy endpoint (`_redeploy_all`) and how to poll its status
- Differences from upstream Supabase (path layout, auth header conventions)
