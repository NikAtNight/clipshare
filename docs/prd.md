# PRD: private video sharing service

Status: Draft v0.3 (supersedes v0.2, kept alongside for reference)
Owner: Nikhil
Working name: ClipShare
Target: Personal MVP
Changed in v0.3: dropped Railway, Postgres, OAuth, link expiry, thumbnails, audit events, and the recovery window. Everything runs on Cloudflare. Decisions and reasons are in section 12.

## 1. Summary

A menu bar Mac app uploads a video to a private R2 bucket and copies a share link. Anyone with the link watches it in a browser. No accounts for viewers, no feed, no comments, nothing public except the link itself.

Only Nikhil uploads. The bucket is private. Links are random, revocable, and don't expire.

## 2. What it has to do

- Drop a video on the Mac app, see progress, get a link on the clipboard when it's done.
- Files up to about 3 GB over normal home Wi-Fi, with per-part retry so a blip doesn't restart the upload.
- Play in current Safari, Chrome, Firefox, and Edge on desktop and phone, with seeking.
- Owner can list uploads, copy a link again, kill a link (which issues a new one), and delete a video.
- No R2 keys or API secrets in the app or the browser.
- A link that's been revoked or deleted shows a generic "not available" page, same response for every failure reason.

Not in scope: viewer accounts, expiry, comments, analytics, multiple owners, server-side transcoding, DRM, iOS app, Finder extension, thumbnails. Some of these are listed as later work in section 11.

## 3. Architecture

Everything is one Cloudflare Worker plus one R2 bucket plus one D1 database.

```text
Mac app  -> Worker (bearer token): create upload, upload parts, complete
Worker   -> R2 binding: multipart upload, no S3 keys involved
Viewer   -> Worker: GET /v/{token}       static viewer page
Viewer   -> Worker: GET /v/{token}/media  streams the object from R2 with Range support
```

Why this shape:

- The Worker streams video from R2 through a binding, so there are no presigned URLs, no expiry, no CORS, and revocation is instant. Every range request checks the token in D1.
- Uploads go through the Worker in parts. Cloudflare's request body limit is 100 MB on Free and Pro accounts, so parts are 50 MB. `uploadPart` accepts the request body stream, nothing gets buffered.
- The viewer is static assets served by the same Worker, so the page and the API share an origin.
- One `wrangler deploy` ships the API, the viewer, and the schema migrations.

Phase 0 has to prove the upload path on the current Workers plan. Workers Free has a 10 ms CPU cap per request. Streaming a body into R2 is I/O, not CPU, so it should fit, but if it doesn't the fixes are either Workers Paid ($5/mo, 30 s CPU) or falling back to presigned S3 part URLs signed by the Worker. Decide only if the proof fails.

## 4. Auth

Machine to machine. One long-lived bearer token.

- Generate the token once with `openssl rand -base64 32`.
- Store its SHA-256 as a Worker secret. Store the raw token in macOS Keychain, pasted into the app on first launch.
- Every owner route requires `Authorization: Bearer <token>` and compares hashes in constant time.
- Rotating means generating a new one, updating the secret, and pasting it into the app again.

No users table, no OAuth, no sessions, no browser management page. The Mac app is the only owner UI.

## 5. Data model (D1)

### videos

- `id` text, random UUID
- `object_key` text, random, unrelated to the filename
- `title` text, defaults to the original filename with control characters stripped
- `original_filename` text
- `size_bytes` integer
- `duration_seconds` real, nullable
- `width`, `height` integer, nullable
- `status` text: `uploading`, `ready`, `failed`
- `upload_id` text, nullable, the R2 multipart upload id while uploading
- `part_size_bytes` integer
- `parts_json` text, the etags of parts uploaded so far
- `share_token` text, unique, 32 random bytes base64url
- `share_revoked_at` integer, nullable
- `created_at`, `ready_at` integer

One video has one live share token. "Revoke" sets `share_revoked_at` and writes a new `share_token`, which is the same power as revoke plus create with one fewer table. Revoked tokens are kept in a small `revoked_tokens` table so a dead token returns the generic page rather than accidentally matching later.

There's no separate upload session table. The upload state lives on the video row.

## 6. Flows

### 6.1 Upload

1. Drop a file or pick one.
2. The app reads container, codecs, size, duration with AVFoundation.
3. The app decides: pass through if it's already H.264 + AAC-LC in MP4 with the `moov` atom at the front; remux with `AVAssetExportPresetPassthrough` and `shouldOptimizeForNetworkUse` if the codecs are fine but the container or atom order isn't; otherwise transcode to H.264 + AAC-LC MP4 with `AVAssetExportSession` (hardware encode on Apple silicon, rotation preserved, 1080p cap unless the source is smaller).
4. `POST /api/videos` with filename, size, duration, dimensions, and a client-generated idempotency key. The Worker creates the row, starts the R2 multipart upload, and returns the video id and part size.
5. The app splits the prepared file into 50 MB parts and PUTs each to `/api/videos/{id}/parts/{n}` with up to three parallel URLSession upload tasks. Each part is retried independently. The Worker streams the body into `uploadPart` and records the etag.
6. `POST /api/videos/{id}/complete`. The Worker finishes the multipart upload, HEADs the object, checks the size matches, sets status `ready`, and returns the share URL. Calling complete twice returns the same result.
7. The app copies the link and shows a success state.

If the app quits mid-upload, on relaunch it asks `GET /api/videos/{id}` which parts landed and resumes from there. The prepared temp file is kept until complete succeeds or the user cancels. Cancel calls `/api/videos/{id}/abort`, which aborts the multipart upload and deletes the row.

Most iPhone footage is HEVC, so expect the transcode path more often than not. The UI shows a "preparing" stage with progress before "uploading" so it's clear what's slow.

### 6.2 Watch

1. Recipient opens `https://<domain>/v/{token}`.
2. The Worker looks up the token. Missing, revoked, or not ready all return the same 404 page.
3. The page is a static HTML file with a `<video>` element pointing at `/v/{token}/media`, `playsinline`, `preload="metadata"`, native controls, the title above it.
4. `/v/{token}/media` re-checks the token on every request, reads the object from R2 with the incoming Range header, and returns 206 with `Content-Range`, `Content-Length`, `Accept-Ranges: bytes`, `Content-Type: video/mp4`, `ETag`. Full GETs without a range return 200.
5. Download button is a link to `/v/{token}/media?download=1`, which sets `Content-Disposition: attachment` with a sanitized filename. It's on by default since anyone who can play the bytes can save them anyway.

### 6.3 Revoke and delete

- Revoke: `POST /api/videos/{id}/revoke`. Old token stops working on the next request. A new token is issued and copied.
- Delete: `DELETE /api/videos/{id}`. The app asks "Delete for real?" and the Worker deletes the R2 object and the row. No recovery window.

## 7. Mac app

SwiftUI menu bar app, AppKit where SwiftUI is missing something (drop target, Finder reveal). AVFoundation for inspection and export. URLSession for uploads. Keychain for the token. Everything off the main actor except UI.

UI:

- Drop zone and Select button
- Current job: filename, size, stage (preparing, uploading), progress, speed, cancel
- Recent uploads list with copy link, open in browser, revoke, delete
- Token entry on first launch, stored in Keychain
- Errors say what failed and offer retry

Rules:

- Never log the token, the share URL, or local paths.
- Never load the whole file into memory. Parts are read with a file handle at an offset.
- Temp files live in the app's caches directory and get cleaned up after a successful complete or an explicit cancel.
- Copy the link only after the Worker reports `ready`.

## 8. Viewer

Static assets bundled with the Worker. One HTML page, one small script to swap the player for the "can't play this" message on a decode error, one stylesheet. No third-party requests of any kind.

Headers on every viewer response:

- `Content-Security-Policy: default-src 'none'; media-src 'self'; style-src 'self'; script-src 'self'; frame-ancestors 'none'`
- `Referrer-Policy: no-referrer`
- `X-Robots-Tag: noindex, nofollow, noarchive`
- `X-Content-Type-Options: nosniff`
- `Cache-Control: no-store` on the page and media endpoints

The token sits in the URL path. It'll show up in browser history and in Cloudflare's edge logs if those are ever turned on. That's accepted. The Worker's own logs strip the path.

Link preview bots (iMessage, WhatsApp) will fetch the page. They'll see the title, which is fine.

## 9. Security in one paragraph

The bucket is private and only the Worker touches it. Owner routes need the bearer token. Share tokens are 256 bits of CSPRNG output and are checked on every media request, so revocation is immediate. Failures all look the same to a viewer. The Mac app and the browser never see an R2 credential. Anyone with a link can watch and forward it, and can record the screen. That's the deal for a share link and nothing here pretends otherwise.

## 10. Operations

- `wrangler` for deploys and D1 migrations. Separate dev and prod bucket, database, and Worker.
- R2 lifecycle rule: abort incomplete multipart uploads after 7 days.
- `wrangler d1 export` weekly is the backup. A cron trigger can do it later if it matters.
- Worker logs with the request path redacted.
- No SLOs, dashboards, or audit tables.

## 11. Phases

### Phase 0: proof

- Worker with an R2 binding and a D1 table.
- `curl` a 200 MB MP4 through the parts endpoints on the current Workers plan. Confirm CPU time doesn't trip.
- Stream it back through `/media` and confirm seeking works in Safari on Mac and iPhone, including a seek to a point past what's buffered and a seek after five minutes of idle.
- A file with the `moov` atom at the end plays only after remux. Confirm the pass-through check catches it.

Exit: one video round trips with no S3 keys and no public object.

### Phase 1: MVP

- Bearer auth, the four owner routes, revoke, delete.
- Static viewer with the headers above and the generic 404.
- Mac app: drop, inspect, pass-through / remux / transcode, parted upload with resume, history list, copy, revoke, delete.
- Dev and prod environments.

Exit: Nikhil uses it for real without touching `wrangler` or `curl`.

### Later, if wanted

- Poster frame (needs a second object and a `poster` attribute; cut for now)
- Optional expiry per link
- Finder Share extension
- FFmpeg helper for MKV, WebM, and other things AVFoundation can't read
- Recovery window on delete

## 12. Decisions made in v0.3 and why

1. Cloudflare only, no Railway. Railway was only there to host a viewer. The Worker serves the viewer and streams from R2 directly, which also removed presigned URLs, CORS, and the expiry problem.
2. Bearer token, not OAuth. One uploader, one machine. A hosted login flow was the biggest chunk of v0.2 that didn't buy anything.
3. No link expiry. Revocation covers the real need. Expiry can come back as a nullable column and a menu later.
4. Multipart from day one, 50 MB parts. The 100 MB Workers body limit forces parts anyway, and parts give resume and retry for free. Single-request upload was never going to survive a 2 GB file on Wi-Fi.
5. No checksum verification. The file comes from Nikhil's own Mac over TLS and R2 checks each part's integrity. The Worker verifies size at complete and that's enough.
6. Thumbnails cut. `preload="metadata"` shows the first frame on desktop browsers, and iOS shows a play button. Good enough.
7. Hard delete with a confirm dialog. A recovery window meant a cron job and more state for a case that a confirm dialog covers.
8. Downloads on by default. Hiding the button doesn't protect anything.
9. One share token per video, regenerate on revoke. Separate share link rows were the multi-tenant version of this.
10. Token in the path, not the URL fragment. Fragment URLs would break link previews and make the viewer need JavaScript to load at all.

Still open: the domain name. Everything else is decided.
