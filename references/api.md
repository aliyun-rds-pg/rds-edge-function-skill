# API Reference

Detailed HTTP contract for the RDS Edge Function platform. Read this when `--help` and `SKILL.md` are not specific enough — e.g. you need an exact metadata field, an error code's meaning, or you're writing your own client.

All paths assume a single base URL:

- `${BASE}` = `SUPABASE_URL` — both the management plane and the Kong route that proxies to user functions

## Authentication

| Endpoint group | Header |
|---|---|
| `/functions/v1/manage/*`, `/secrets/v1*` | `Authorization: Bearer ${SUPABASE_ANON_KEY}` |
| `/functions/v1/<slug>` (invoke) | `Authorization: Bearer ${SUPABASE_ANON_KEY}` — only required when the function was deployed with `verify_jwt: true` |

Both groups also accept `apikey: <key>` as an alternative header.

The Kong gateway accepts the anon key on these routes (ACL group `anon` is whitelisted). The service-role key is **not** required by anything in this skill — prefer the anon key, since it is less privileged and is what the Edge Function console hands out via its `/skills` page anyway.

## Error envelope

Errors are returned with a `code` + `message` body:

```json
{"code": "VALIDATION_ERROR", "message": "Invalid metadata JSON: ..."}
```

| Code | HTTP | When |
|---|---|---|
| `VALIDATION_ERROR` | 400 | Bad JSON, missing required fields |
| `E2B_NOT_ENABLED` | 400 | Sandbox/edge function feature is disabled on this instance |
| `CODE_CHECK_FAILED` | 400 | Static code analysis rejected the upload |
| `UNAUTHORIZED` | 401 | Missing/invalid token (only on JWT-protected invokes) |
| `NOT_FOUND` | 404 | Function slug or secret name does not exist |
| `CONFLICT` | 409 | Rename collides with existing slug |
| `REDEPLOY_IN_PROGRESS` | 409 | A batch redeploy is already running |
| `INVALID_ARCHIVE` | 422 | Downloaded body is not a valid zip |
| `SANDBOX_ERROR` | 500 | Resource manager failed to create/start a sandbox |
| `DOWNLOAD_ERROR` | 502 | Cannot fetch `downloadUrl` |
| `SERVICE_UNAVAILABLE` | 503 | DB not initialized |

## Function management

### `GET ${BASE}/functions/v1/manage`

List all functions. Returns `FunctionResponse[]` (Supabase community shape).

### `POST ${BASE}/functions/v1/manage/deploy?slug=<slug>`

Deploy (create or upgrade) a function. Accepts two content types:

**`multipart/form-data`** — most common, used by `deploy.sh`:

| Part | Required | Description |
|---|---|---|
| `metadata` | yes | JSON object, schema below |
| `file` | yes (repeatable) | One or more source files. If a single `.zip` is sent, it is treated as a pre-packaged bundle; otherwise files are zipped server-side preserving the relative paths in their `filename`. |

`metadata` schema (custom, not the official Supabase shape):

| Field | Type | Notes |
|---|---|---|
| `name` | string | Defaults to `slug` |
| `verify_jwt` | bool | Default `true`. When `false`, function is public (no anon key required) |
| `entrypoint_path` | string | E.g. `index.ts`. Used to synthesize `deno run --allow-net --allow-env /code/<entrypoint_path>` |
| `static_patterns` | string[] | Glob patterns for non-source files to bundle |

**`application/json`** — used for URL deploy:

```json
{
  "downloadUrl": "https://storage.example.com/code.zip",
  "command": "deno run --allow-net --allow-env /code/index.ts",
  "metadata": {"verify_jwt": true, "name": "my-func", "entrypoint_path": "index.ts"}
}
```

If `command` is given it takes priority over the entrypoint-derived command. URL deploy requires `slug` in the query string.

### `GET ${BASE}/functions/v1/manage/<slug>`

Get details for one function.

### `PATCH ${BASE}/functions/v1/manage/<slug>`

Update fields. Body:

```json
{
  "name": "new-slug",
  "downloadUrl": "...",
  "command": "...",
  "verify_jwt": false,
  "status": "ready"
}
```

Changing `downloadUrl` or `command` triggers a sandbox redeploy. Changing `name` renames the slug and reconfigures the Kong route.

### `DELETE ${BASE}/functions/v1/manage/<slug>`

Delete one function. Removes its sandbox and Kong route.

### `DELETE ${BASE}/functions/v1/manage`

Bulk delete all functions. Returns `{deleted, failed, errors}`.

### `GET ${BASE}/functions/v1/manage/<slug>/body`

Return the function's source as `multipart/form-data` — useful for re-downloading and re-packing code without going through Storage directly.

### `POST ${BASE}/functions/v1/manage/<slug>/_ensure`

Idempotent "wake up" call. If the function's sandbox was auto-paused, this resumes it. Returns `{status:"ok", backend:"<url>"}`. Invocations through Kong call this implicitly, but explicit calls are useful for warming.

### `POST ${BASE}/functions/v1/manage/_redeploy_all`

Trigger an async batch redeploy of every function. Returns `202 {status:"accepted"}` immediately; only one batch may run at a time (409 `REDEPLOY_IN_PROGRESS` otherwise).

### `GET ${BASE}/functions/v1/manage/_redeploy_all/status`

Poll batch-redeploy progress: `{in_progress: bool, results?: {succeeded, failed, total, details}}`.

## Invoking a function

### `POST ${BASE}/functions/v1/<slug>`

Standard Supabase-style invoke. Kong forwards to the function's sandbox on port 8000.

- Body and headers are passed through to the function
- When `verify_jwt: true`, requests without a valid `Authorization: Bearer <anon|service key>` are rejected
- The function process is responsible for routing/methods; the platform only proxies

## Secret management

Secrets are injected as env vars at sandbox creation time. **A function must be redeployed to pick up a new secret value.**

### `GET ${BASE}/secrets/v1`

List all secrets (values are SHA-256 masked).

### `POST ${BASE}/secrets/v1`

Upsert. Body: `[{"name":"K","value":"V"}, ...]`. Returns `{created, updated, total}`.

### `PUT ${BASE}/secrets/v1`

Update only (does not create). Returns `{updated, not_found, total}`.

### `DELETE ${BASE}/secrets/v1`

Bulk delete. Body: `["K1","K2"]`. Returns `{deleted, not_found, total}`.

### `DELETE ${BASE}/secrets/v1/<name>`

Delete one secret.

## Notes on divergence from upstream Supabase

| Aspect | Upstream | RDS |
|---|---|---|
| Base path | `/v1/projects/{ref}/functions/...` | `/functions/v1/manage/...` (no project ref) |
| Deploy body | Multipart only | Multipart **or** JSON `{downloadUrl, command, metadata}` |
| Invoke port | N/A (managed) | Function must bind `0.0.0.0:8000` |
| Bulk redeploy | Not available | `/functions/v1/manage/_redeploy_all` |
