# Deploying ClipShare

One-time setup on the Cloudflare account, then `pnpm run deploy` for every change. Nothing here has been run yet; the Worker has only been exercised locally under `wrangler dev`.

## 1. Create the owner token

```sh
TOKEN=$(openssl rand -base64 32)
echo "$TOKEN"                                  # paste this into the Mac app once
printf '%s' "$TOKEN" | shasum -a 256           # the hex on the left is the secret below
```

Keep the raw token in a password manager. The Worker only ever sees the hash.

## 2. Create the bucket and database

```sh
cd worker
pnpm exec wrangler r2 bucket create clipshare
pnpm exec wrangler r2 bucket create clipshare-dev          # optional, used by wrangler dev --remote
pnpm exec wrangler d1 create clipshare                     # prints a database_id
```

Put the printed `database_id` into both `d1_databases` entries in `wrangler.jsonc` (the top-level one and `env.production`), replacing `REPLACE_ME`.

Set a lifecycle rule on the `clipshare` bucket in the dashboard: abort incomplete multipart uploads after 7 days. That's the only cleanup the design relies on.

## 3. Secrets and schema

```sh
pnpm exec wrangler secret put OWNER_TOKEN_SHA256 --env production   # paste the hex from step 1
pnpm run migrate:prod
```

## 4. Domain

`wrangler.jsonc` already declares `clips.talix.app` as a custom domain for the production environment. Since `talix.app` is on this Cloudflare account, the first `deploy` creates the DNS record and certificate automatically. To use a different hostname, change the `pattern` in the `routes` entry and `PUBLIC_BASE_URL`, both under `env.production`.

## 5. Deploy

```sh
pnpm run deploy
```

Then, from any machine:

```sh
curl -i https://clips.talix.app/api/videos                              # expect 401
curl -i -H "Authorization: Bearer $TOKEN" https://clips.talix.app/api/videos   # expect 200 {"videos":[],...}
```

## 6. Phase 0 check that still has to happen in production

Workers Free caps CPU at 10 ms per request. Streaming a 50 MB part into R2 is I/O, not CPU, so it should fit, but it has only been proven under Miniflare. After the first deploy, upload a real video from the Mac app and watch for `Error 1102` (CPU exceeded) in `pnpm exec wrangler tail --env production`. If it shows up, the fix is Workers Paid ($5/month, 30 s CPU). Nothing in the code needs to change.

## Rotating the token

Repeat step 1, `wrangler secret put` the new hash, then paste the new token into the Mac app under Settings. The old token stops working the moment the secret is updated.

## Local development

```sh
cd worker
cp .dev.vars.example .dev.vars    # fill in OWNER_TOKEN_SHA256, optionally PART_SIZE_BYTES=5242880 for small test parts
pnpm run migrate:local
pnpm run dev                       # http://localhost:8787
```

Point the Mac app at `http://localhost:8787` in Settings to test against it.
