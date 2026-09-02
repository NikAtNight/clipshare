# ClipShare

Private video sharing for one person. A macOS menu bar app uploads a video to a private Cloudflare R2 bucket through a Cloudflare Worker, then puts a share link on your clipboard. Anyone with the link watches it in a browser. No accounts for viewers, no feed, no comments, no download button.

## How it works

- The Mac app inspects the video and passes it through, remuxes it, or hardware-transcodes it to an H.264 MP4 with the moov atom up front, so it plays in every browser.
- Upload goes to the Worker in 50 MiB parts straight into R2 multipart. Interrupted uploads resume after relaunch.
- Playback streams from R2 through the Worker with range support. Every request checks the share token, so revoking a link is instant. Links never expire on their own.
- Owner auth is a single bearer token stored in the macOS Keychain. Viewers need nothing.
- A floating drop target appears when you drag a video anywhere on screen, so you never have to open the menu.

## Layout

- `worker/` Cloudflare Worker (TypeScript, Hono, D1, R2, static viewer). Package manager is bun.
- `mac/` SwiftPM package: `ClipShareCore` (media pipeline, upload client, Keychain) and the `ClipShare` SwiftUI app. `scripts/make-app.sh` builds `build/ClipShare.app`.
- `docs/prd.md` design, `docs/api.md` the contract between the two halves, `docs/deploy.md` how to ship it.

## Run it locally

```sh
cd worker
bun install
cp .dev.vars.example .dev.vars   # put in the SHA-256 of your owner token
bun run migrate:local
bun run dev                      # http://localhost:8787

cd ../mac
./scripts/make-app.sh
open build/ClipShare.app         # point Settings at http://localhost:8787 and paste the token
```

Tests: `bun run test` in `worker/`, `swift test` in `mac/`.

## Deploy

See `docs/deploy.md`. Everything runs on Cloudflare: one Worker, one D1 database, one R2 bucket, one custom domain.
