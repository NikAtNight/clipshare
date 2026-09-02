import { defineWorkersConfig, readD1Migrations } from "@cloudflare/vitest-pool-workers/config";

const migrations = await readD1Migrations("./migrations");

export default defineWorkersConfig({
  test: {
    pool: "@cloudflare/vitest-pool-workers",
    setupFiles: ["./test/setup.ts"],
    provide: { migrations },
    poolOptions: {
      workers: {
        isolatedStorage: false,
        wrangler: { configPath: "./wrangler.jsonc" },
        miniflare: {
          bindings: {
            OWNER_TOKEN_SHA256: "98bf3ce5701da62eae2a845fd1907c7b01783930d71d67389047ea7c530c68bb",
            // R2 requires 5 MiB for each non-final multipart part, so tests use that minimum.
            PART_SIZE_BYTES: "5242880"
          }
        }
      }
    }
  }
});
