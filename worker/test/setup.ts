import { applyD1Migrations, env } from "cloudflare:test";
import { beforeAll, inject } from "vitest";
import type { D1Migration } from "@cloudflare/vitest-pool-workers/config";

beforeAll(async () => {
  await applyD1Migrations(env.DB, inject("migrations") as D1Migration[]);
});
