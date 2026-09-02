# ClipShare

Personal private video sharing. A macOS menu bar app uploads a video to a private R2 bucket through a Cloudflare Worker, then copies a share link. Anyone with the link watches in a browser. One owner, one bearer token, no viewer accounts.

Read `docs/prd.md` for what and why, `docs/api.md` for the contract between the two halves. The contract is pinned: change `docs/api.md` first, then both sides.

## Layout

- `worker/` Cloudflare Worker (TypeScript, Hono, D1, R2 binding, static viewer assets). Package manager is pnpm.
- `mac/` SwiftPM package. `ClipShareCore` library (media pipeline, upload client, Keychain), `ClipShare` executable (SwiftUI menu bar app), tests, and `scripts/make-app.sh` that builds the `.app` bundle.

## Commands

Worker (run in `worker/`):
- `pnpm install`
- `pnpm run check` typecheck
- `pnpm run test` vitest against Miniflare with local D1 and R2
- `pnpm run dev` local server on http://localhost:8787 (reads `.dev.vars` for `OWNER_TOKEN_SHA256`)

Mac (run in `mac/`):
- `swift build`
- `swift test`
- `./scripts/make-app.sh` builds `build/ClipShare.app`

## Rules

- Never log the bearer token, share tokens, share URLs, object keys, or local file paths.
- Viewer failures all return the same generic 404 page. Don't leak whether a video existed.
- The Worker never exposes R2 to the browser. Playback streams through `/v/{token}/media`.
- Mac side: nothing on the main actor except UI. Never read a whole video into memory.
- Plain prose in comments and docs. No em dashes.
- Do not commit. Nikhil commits.

## Deploying

See `docs/deploy.md`. Deploys and DNS changes are Nikhil's call, never automatic.
