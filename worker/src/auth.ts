import type { MiddlewareHandler } from "hono";
import type { Env } from "./env";

function hex(bytes: ArrayBuffer): string {
  return [...new Uint8Array(bytes)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export const ownerAuth: MiddlewareHandler<{ Bindings: Env; Variables: { route: string } }> = async (context, next) => {
  context.set("route", "owner_api");
  const value = context.req.header("Authorization");
  const token = value?.startsWith("Bearer ") ? value.slice(7) : "";
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token));
  const actual = new TextEncoder().encode(hex(digest));
  const expected = new TextEncoder().encode(context.env.OWNER_TOKEN_SHA256 ?? "");
  const sameLength = actual.byteLength === expected.byteLength;
  const comparisonTarget = sameLength ? expected : actual;
  const subtle = crypto.subtle as SubtleCrypto & { timingSafeEqual(left: BufferSource, right: BufferSource): boolean };
  const matches = subtle.timingSafeEqual(actual, comparisonTarget) && sameLength;

  if (!matches) return context.json({ error: "unauthorized" }, 401);
  await next();
};
