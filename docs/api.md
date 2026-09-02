# ClipShare API contract

This is the contract between the Mac app and the Worker. Both sides are built against this file. Change it here first, then change both sides.

Base URL: `https://clips.talix.app` in production, `http://localhost:8787` under `wrangler dev`. The Worker reads `PUBLIC_BASE_URL` from its config and uses it to build share URLs.

## Auth

Every route under `/api/` requires `Authorization: Bearer <token>`. The Worker holds `OWNER_TOKEN_SHA256`, the lowercase hex SHA-256 of the token, as a secret. Compare with a constant-time equality check. Missing or wrong token: `401 {"error":"unauthorized"}`.

Viewer routes under `/v/` take no auth.

## Errors

JSON body `{"error": "<snake_case_code>", "message": "<short human sentence>"}` with a matching status. Never include tokens, object keys, or stack traces.

Viewer routes never return JSON errors. Every failure is the same generic HTML 404 page (see below).

## Video object

```json
{
  "id": "6f1c…",                 // UUID v4
  "title": "Beach day",          // defaults to originalFilename without its extension, control characters stripped
  "originalFilename": "IMG_1234.MOV",
  "sizeBytes": 123456789,        // size of the prepared upload, not the source
  "durationSeconds": 42.5,       // nullable
  "width": 1920,                 // nullable
  "height": 1080,                // nullable
  "status": "uploading",         // uploading | ready | failed
  "shareEnabled": true,          // false while the owner has switched the link off
  "shareUrl": null,              // "<PUBLIC_BASE_URL>/v/<token>" once ready, else null (present even when disabled)
  "createdAt": "2026-09-01T18:00:00.000Z",
  "readyAt": null
}
```

## Owner routes

### `POST /api/videos`
Start an upload.

The title defaults to originalFilename without its extension, control characters stripped.

Request:
```json
{
  "idempotencyKey": "client-generated uuid",
  "originalFilename": "IMG_1234.MOV",
  "sizeBytes": 123456789,
  "durationSeconds": 42.5,
  "width": 1920,
  "height": 1080
}
```
- `sizeBytes` must be > 0 and <= 5368709120 (5 GiB). Otherwise `400 invalid_size`.
- Creates the D1 row with `status = uploading`, a random object key, a random share token, and an R2 multipart upload.
- Response `201 { "video": Video, "partSizeBytes": 52428800, "partCount": 3 }`.
- If `idempotencyKey` was already used: `200` with the same shape for the existing video, no new row.

Part size is fixed at 50 MiB (52428800). `partCount = ceil(sizeBytes / partSizeBytes)`.

### `PUT /api/videos/{id}/parts/{n}`
Upload one part. Raw body, `Content-Type: application/octet-stream`, `Content-Length` required.

- `n` is 1-based and must be in `1..partCount`, else `400 invalid_part`.
- Expected size for part `n` is `partSizeBytes`, except the last part which is `sizeBytes - (partCount - 1) * partSizeBytes`. If `Content-Length` differs: `400 part_size_mismatch` before reading the body.
- The Worker streams `request.body` into `uploadPart(n, body)` and stores the returned etag on the row.
- Uploading the same part again replaces the earlier etag.
- Video not in `uploading` status: `409 not_uploading`.
- Response `200 { "partNumber": 2, "etag": "…", "sizeBytes": 52428800 }`.

### `GET /api/videos/{id}`
Status, used for resume after relaunch.

Response `200 { "video": Video, "partSizeBytes": 52428800, "partCount": 3, "uploadedParts": [1, 3] }`. Unknown id: `404 not_found`.

### `POST /api/videos/{id}/complete`
Finish the upload. No body.

- If status is already `ready`: `200 { "video": Video, "shareUrl": "…" }` with no changes. Safe to call twice.
- If any part is missing: `409 { "error": "parts_missing", "missing": [2] }`.
- Otherwise completes the multipart upload, `head()`s the object, and checks `size === sizeBytes`.
  - Match: status `ready`, `readyAt` set. Response `200 { "video": Video, "shareUrl": "…" }`.
  - Mismatch: delete the object, status `failed`. Response `422 size_mismatch`.

### `POST /api/videos/{id}/abort`
Cancel an in-progress upload. Aborts the multipart upload and deletes the row. `204`. Only valid while `uploading`, else `409 not_uploading`.

### `GET /api/videos?limit=50&cursor=<opaque>&q=<text>`
Newest first, all statuses. `limit` defaults to 50, max 200. `q` is optional: trimmed, max 100 characters, matched case-insensitively as a substring against both `title` and `originalFilename` (`%` and `_` in `q` are escaped, so they match literally). The cursor encodes the position only; the caller sends the same `q` on every page. Response `200 { "videos": [Video], "nextCursor": "…" | null }`.

### `PATCH /api/videos/{id}`
Request `{ "title": "New title", "shareEnabled": false }`. Both fields optional, at least one required (`400 invalid_request` otherwise). Title is trimmed, control characters stripped, max 200 chars, must be non-empty. `shareEnabled: false` switches the link off without changing the token; the viewer returns the generic 404 until it's switched back on. Response `200 { "video": Video }`.

### `POST /api/videos/{id}/revoke`
Kill the current share link and issue a new one. Old token returns the generic 404 immediately. Response `200 { "video": Video, "shareUrl": "…" }`. Only valid when `ready`, else `409 not_ready`.

### `DELETE /api/videos/{id}`
Delete the video. If `uploading`, aborts the multipart upload first. Deletes the R2 object and the row. `204`. Unknown id: `404`.

## Viewer routes

### `GET /v/{token}`
- Token matches a `ready` video whose link is enabled: `200` HTML viewer page.
- Anything else (unknown, not ready, deleted): `404` with the generic unavailable page. Same bytes for every reason.

### `GET|HEAD /v/{token}/media?e={exp}&s={sig}`
- Looks the token up on every request.
- Requires a page-generated signature. The viewer page signs the share token with HMAC-SHA-256 using `OWNER_TOKEN_SHA256` and renders `src="/v/{token}/media?s={sig}"`. The signature never expires on its own; revoking the link replaces the token and invalidates every media URL built from it.
- If present, `Sec-Fetch-Dest` must be `video`, `audio`, or `empty`. If present, `Sec-Fetch-Site` must be `same-origin` or `none`.
- Reads the object from R2 with the incoming `Range` header passed through to `get(key, { range: request.headers })`.
- No `Range`: `200` with the full body. `Range`: `206` with `Content-Range`.
- Headers on success: `Content-Type: video/mp4`, `Accept-Ranges: bytes`, `Content-Length`, `ETag`, `Cache-Control: no-store`, `Content-Disposition: inline`, `Cross-Origin-Resource-Policy: same-origin`.
- Unsatisfiable range: `416`.
- Invalid token, missing or invalid signature, and rejected fetch metadata all return the same generic `404` page as above.

### Headers on every `/v/` response
```
Content-Security-Policy: default-src 'none'; media-src 'self'; style-src 'self'; script-src 'self'; img-src 'self'; frame-ancestors 'none'
Referrer-Policy: no-referrer
X-Robots-Tag: noindex, nofollow, noarchive
X-Content-Type-Options: nosniff
Cache-Control: no-store
```

## Tokens and keys

- Share token: 32 bytes from `crypto.getRandomValues`, base64url without padding (43 chars).
- Object key: `videos/<32 hex chars>.mp4`, random, never derived from the filename.
- Video id: `crypto.randomUUID()`.

## D1 schema

```sql
CREATE TABLE videos (
  id TEXT PRIMARY KEY,
  object_key TEXT NOT NULL UNIQUE,
  title TEXT NOT NULL,
  original_filename TEXT NOT NULL,
  size_bytes INTEGER NOT NULL,
  duration_seconds REAL,
  width INTEGER,
  height INTEGER,
  status TEXT NOT NULL CHECK (status IN ('uploading', 'ready', 'failed')),
  upload_id TEXT,
  part_size_bytes INTEGER NOT NULL,
  part_count INTEGER NOT NULL,
  parts_json TEXT NOT NULL DEFAULT '[]',   -- [{"partNumber":1,"etag":"…"}]
  share_token TEXT NOT NULL UNIQUE,
  idempotency_key TEXT UNIQUE,
  created_at INTEGER NOT NULL,             -- unix ms
  ready_at INTEGER,
  share_enabled INTEGER NOT NULL DEFAULT 1  -- added in migration 0002
);
CREATE INDEX videos_created_at ON videos (created_at DESC);
```

A revoked token is simply replaced. With 256 bits of randomness an old token can't collide with a new one, so there is no revoked-token table.
