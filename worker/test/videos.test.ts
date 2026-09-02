import { env, SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

const ownerToken = "owner-token-for-tests";
const partSize = 5_242_880;

function ownerHeaders(): HeadersInit {
  return { Authorization: `Bearer ${ownerToken}` };
}

async function request(path: string, init: RequestInit = {}): Promise<Response> {
  const headers = new Headers(init.headers);
  if (init.body instanceof Uint8Array && !headers.has("Content-Length")) headers.set("Content-Length", String(init.body.byteLength));
  return SELF.fetch(`https://clipshare.test${path}`, { ...init, headers });
}

async function createVideo(overrides: Record<string, unknown> = {}) {
  const response = await request("/api/videos", {
    method: "POST",
    headers: { ...ownerHeaders(), "Content-Type": "application/json" },
    body: JSON.stringify({
      idempotencyKey: crypto.randomUUID(),
      originalFilename: "beach.mp4",
      sizeBytes: partSize + 137,
      durationSeconds: 3.5,
      width: 1920,
      height: 1080,
      ...overrides
    })
  });
  return { response, body: await response.json() as any };
}

async function upload(response: any, partNumber: number, bytes: Uint8Array): Promise<Response> {
  return request(`/api/videos/${response.video.id}/parts/${partNumber}`, {
    method: "PUT",
    headers: { ...ownerHeaders(), "Content-Type": "application/octet-stream", "Content-Length": String(bytes.byteLength) },
    body: bytes
  });
}

async function readyVideo(title = "beach.mp4") {
  const created = await createVideo({ originalFilename: title });
  const first = new Uint8Array(partSize).fill(65);
  const final = new Uint8Array(137).fill(66);
  await upload(created.body, 1, first);
  await upload(created.body, 2, final);
  const complete = await request(`/api/videos/${created.body.video.id}/complete`, { method: "POST", headers: ownerHeaders() });
  const bytes = new Uint8Array(first.byteLength + final.byteLength);
  bytes.set(first);
  bytes.set(final, first.byteLength);
  return { created: created.body, complete, bytes };
}

async function signedMediaPath(shareUrl: string): Promise<string> {
  const page = await request(new URL(shareUrl).pathname);
  expect(page.status).toBe(200);
  const source = (await page.text()).match(/<video[^>]*\bsrc="([^"]+)"/)?.[1];
  expect(source).toBeDefined();
  return new URL(source!, "https://clipshare.test").pathname + new URL(source!, "https://clipshare.test").search;
}

function viewerHeaders(response: Response) {
  expect(response.headers.get("Referrer-Policy")).toBe("no-referrer");
  expect(response.headers.get("X-Robots-Tag")).toBe("noindex, nofollow, noarchive");
  expect(response.headers.get("Content-Security-Policy")).toContain("default-src 'none'");
  expect(response.headers.get("X-Content-Type-Options")).toBe("nosniff");
  expect(response.headers.get("Cache-Control")).toBe("no-store");
}

describe("ClipShare Worker", () => {
  it("rejects missing, wrong, and differently sized owner tokens", async () => {
    for (const headers of [{}, { Authorization: "Bearer wrong" }, { Authorization: "Bearer x".repeat(100) }]) {
      const response = await request("/api/videos", { headers });
      expect(response.status).toBe(401);
      await expect(response.json()).resolves.toEqual({ error: "unauthorized" });
    }
  });

  it("creates, resumes, completes, and reports a two-part upload", async () => {
    const created = await createVideo();
    expect(created.response.status).toBe(201);
    expect(created.body.partSizeBytes).toBe(partSize);
    expect(created.body.partCount).toBe(2);
    await expect(upload(created.body, 1, new Uint8Array(partSize).fill(65))).resolves.toHaveProperty("status", 200);
    await expect(upload(created.body, 2, new Uint8Array(137).fill(66))).resolves.toHaveProperty("status", 200);
    const status = await request(`/api/videos/${created.body.video.id}`, { headers: ownerHeaders() });
    expect((await status.json()).uploadedParts).toEqual([1, 2]);
    const complete = await request(`/api/videos/${created.body.video.id}/complete`, { method: "POST", headers: ownerHeaders() });
    expect(complete.status).toBe(200);
    expect((await complete.json()).shareUrl).toContain("/v/");
    const ready = await request(`/api/videos/${created.body.video.id}`, { headers: ownerHeaders() });
    expect((await ready.json()).video.status).toBe("ready");
  });

  it("uses the original upload for a repeated idempotency key", async () => {
    const key = crypto.randomUUID();
    const first = await createVideo({ idempotencyKey: key });
    const second = await createVideo({ idempotencyKey: key });
    expect(second.response.status).toBe(200);
    expect(second.body.video.id).toBe(first.body.video.id);
    const count = await env.DB.prepare("SELECT count(*) AS total FROM videos WHERE idempotency_key = ?").bind(key).first<{ total: number }>();
    expect(count?.total).toBe(1);
  });

  it("reports each missing part when completion is premature", async () => {
    const created = await createVideo();
    await upload(created.body, 1, new Uint8Array(partSize));
    const response = await request(`/api/videos/${created.body.video.id}/complete`, { method: "POST", headers: ownerHeaders() });
    expect(response.status).toBe(409);
    expect(await response.json()).toEqual({ error: "parts_missing", missing: [2] });
  });

  it("makes complete safe to repeat", async () => {
    const ready = await readyVideo();
    expect(ready.complete.status).toBe(200);
    const again = await request(`/api/videos/${ready.created.video.id}/complete`, { method: "POST", headers: ownerHeaders() });
    expect(again.status).toBe(200);
  });

  it("recovers when R2 finalized before the ready row update", async () => {
    const created = await createVideo();
    const uploadID = await env.DB.prepare("SELECT upload_id FROM videos WHERE id = ?").bind(created.body.video.id).first<{ upload_id: string }>();
    await upload(created.body, 1, new Uint8Array(partSize).fill(65));
    await upload(created.body, 2, new Uint8Array(137).fill(66));
    const first = await request(`/api/videos/${created.body.video.id}/complete`, { method: "POST", headers: ownerHeaders() });
    expect(first.status).toBe(200);
    await env.DB.prepare("UPDATE videos SET status = 'uploading', upload_id = ? WHERE id = ?").bind(uploadID?.upload_id, created.body.video.id).run();
    const recovered = await request(`/api/videos/${created.body.video.id}/complete`, { method: "POST", headers: ownerHeaders() });
    expect(recovered.status).toBe(200);
    expect((await recovered.json()).video.status).toBe("ready");
  });

  it("rejects an incorrectly sized part before reading it", async () => {
    const created = await createVideo();
    const response = await request(`/api/videos/${created.body.video.id}/parts/1`, {
      method: "PUT",
      headers: { ...ownerHeaders(), "Content-Length": "1" },
      body: new Uint8Array([1])
    });
    expect(response.status).toBe(400);
    expect((await request(`/api/videos/${created.body.video.id}`, { headers: ownerHeaders() }).then((item) => item.json())).uploadedParts).toEqual([]);
  });

  it("renders escaped titles and keeps non-ready videos unavailable", async () => {
    const created = await createVideo({ originalFilename: "<script>alert(1)</script>.mp4" });
    const uploadingToken = await env.DB.prepare("SELECT share_token FROM videos WHERE id = ?").bind(created.body.video.id).first<{ share_token: string }>();
    const notReady = await request(`/v/${uploadingToken!.share_token}`);
    expect(notReady.status).toBe(404);
    const ready = await readyVideo("<script>alert(1)</script>");
    const token = ready.created.video.shareUrl ?? (await ready.complete.clone().json()).shareUrl;
    const page = await request(new URL(token).pathname);
    expect(page.status).toBe(200);
    expect(await page.text()).toContain("&lt;script&gt;alert(1)&lt;/script&gt;");
  });

  it("streams full, byte range, suffix range, unsatisfiable range, and HEAD media responses", async () => {
    const ready = await readyVideo();
    const shareUrl = (await ready.complete.clone().json()).shareUrl as string;
    const path = await signedMediaPath(shareUrl);
    const full = await request(path);
    expect(full.status).toBe(200);
    expect(full.headers.get("Content-Disposition")).toBe("inline");
    expect(full.headers.get("Cross-Origin-Resource-Policy")).toBe("same-origin");
    expect(new Uint8Array(await full.arrayBuffer())).toEqual(ready.bytes);
    const ranged = await request(path, { headers: { Range: "bytes=0-99" } });
    expect(ranged.status).toBe(206);
    expect(ranged.headers.get("Content-Range")).toBe(`bytes 0-99/${ready.bytes.byteLength}`);
    expect(new Uint8Array(await ranged.arrayBuffer())).toEqual(ready.bytes.slice(0, 100));
    const suffix = await request(path, { headers: { Range: "bytes=-10" } });
    expect(suffix.status).toBe(206);
    expect(new Uint8Array(await suffix.arrayBuffer())).toEqual(ready.bytes.slice(-10));
    const unsatisfiable = await request(path, { headers: { Range: `bytes=${ready.bytes.byteLength}-` } });
    expect(unsatisfiable.status).toBe(416);
    expect(unsatisfiable.headers.get("Content-Range")).toBe(`bytes */${ready.bytes.byteLength}`);
    const head = await request(path, { method: "HEAD" });
    expect(head.status).toBe(200);
    expect(head.headers.get("Content-Length")).toBe(String(ready.bytes.byteLength));
    expect(await head.text()).toBe("");
  });

  it("rejects missing and tampered media signatures with the generic unavailable page", async () => {
    const ready = await readyVideo("../unsafe/\"name\"");
    const shareUrl = (await ready.complete.clone().json()).shareUrl as string;
    const viewerPath = new URL(shareUrl).pathname;
    const unknown = await request("/v/not-a-real-token");
    const missing = await request(`${viewerPath}/media`);
    const missingHead = await request(`${viewerPath}/media`, { method: "HEAD" });
    const signedPath = await signedMediaPath(shareUrl);
    const tamperedUrl = new URL(signedPath, "https://clipshare.test");
    tamperedUrl.searchParams.set("s", `${tamperedUrl.searchParams.get("s")!.slice(0, -1)}x`);
    const tampered = await request(tamperedUrl.pathname + tamperedUrl.search);
    for (const response of [missing, tampered]) {
      expect(response.status).toBe(404);
      expect(await response.text()).toBe(await unknown.clone().text());
    }
    expect(missingHead.status).toBe(404);
  });

  it("drops the source extension from the default title", async () => {
    const ready = await readyVideo("beach day.MOV");
    expect(ready.created.video.title).toBe("beach day");
  });

  it("rejects document fetches and accepts video fetches for a signed media URL", async () => {
    const ready = await readyVideo();
    const path = await signedMediaPath((await ready.complete.clone().json()).shareUrl as string);
    const rejected = await request(path, { headers: { "Sec-Fetch-Dest": "document" } });
    expect(rejected.status).toBe(404);
    const accepted = await request(path, { headers: { "Sec-Fetch-Dest": "video", Range: "bytes=0-99" } });
    expect(accepted.status).toBe(206);
  });

  it("renders a playback-only video element", async () => {
    const ready = await readyVideo();
    const page = await request(new URL((await ready.complete.clone().json()).shareUrl as string).pathname);
    const html = await page.text();
    expect(html).toMatch(/<video[^>]*controlslist="nodownload noremoteplayback"/);
    expect(html).not.toMatch(/<a\b[^>]*>\s*Download\s*<\/a>/i);
  });

  it("revokes the old viewer token and issues a working one", async () => {
    const ready = await readyVideo();
    const oldPath = new URL((await ready.complete.clone().json()).shareUrl).pathname;
    const revoked = await request(`/api/videos/${ready.created.video.id}/revoke`, { method: "POST", headers: ownerHeaders() });
    const newPath = new URL((await revoked.json()).shareUrl).pathname;
    expect((await request(oldPath)).status).toBe(404);
    expect((await request(newPath)).status).toBe(200);
  });

  it("deletes the object and hides deleted videos", async () => {
    const ready = await readyVideo();
    const object = await env.DB.prepare("SELECT object_key FROM videos WHERE id = ?").bind(ready.created.video.id).first<{ object_key: string }>();
    const path = new URL((await ready.complete.clone().json()).shareUrl).pathname;
    expect((await request(`/api/videos/${ready.created.video.id}`, { method: "DELETE", headers: ownerHeaders() })).status).toBe(204);
    expect(await env.BUCKET.head(object!.object_key)).toBeNull();
    expect((await request(path)).status).toBe(404);
    const listed = await request("/api/videos", { headers: ownerHeaders() });
    expect((await listed.json()).videos.find((video: any) => video.id === ready.created.video.id)).toBeUndefined();
  });

  it("uses identical protected 404 pages and headers for every viewer failure", async () => {
    const ready = await readyVideo();
    const oldPath = new URL((await ready.complete.clone().json()).shareUrl).pathname;
    await request(`/api/videos/${ready.created.video.id}/revoke`, { method: "POST", headers: ownerHeaders() });
    const unknown = await request("/v/not-a-real-token");
    const revoked = await request(oldPath);
    expect(unknown.status).toBe(404);
    expect(await unknown.text()).toBe(await revoked.text());
    viewerHeaders(revoked);
    viewerHeaders(await request("/v/not-a-real-token/media"));
  });

  it("lists videos newest first with cursor pagination", async () => {
    const one = await createVideo({ originalFilename: "one.mp4", sizeBytes: 1 });
    await new Promise((resolve) => setTimeout(resolve, 2));
    const two = await createVideo({ originalFilename: "two.mp4", sizeBytes: 1 });
    const first = await request("/api/videos?limit=1", { headers: ownerHeaders() });
    const firstBody = await first.json() as any;
    expect(firstBody.videos[0].id).toBe(two.body.video.id);
    expect(firstBody.nextCursor).toBeTypeOf("string");
    const second = await request(`/api/videos?limit=1&cursor=${encodeURIComponent(firstBody.nextCursor)}`, { headers: ownerHeaders() });
    expect((await second.json()).videos[0].id).toBe(one.body.video.id);
  });
});
