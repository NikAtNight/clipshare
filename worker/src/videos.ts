import { Hono } from "hono";
import type { Context } from "hono";
import { HTTPException } from "hono/http-exception";
import { parseParts, savePart, toVideo, videoById, videoByIdempotencyKey } from "./db";
import type { Env, VideoRow } from "./env";
import { randomObjectKey, randomShareToken } from "./tokens";

const DEFAULT_PART_SIZE = 52_428_800;
const MIN_R2_PART_SIZE = 5_242_880;
const MAX_SIZE = 5_368_709_120;

type App = { Bindings: Env; Variables: { route: string } };

function error(context: Context<App>, status: 400 | 404 | 409 | 422, code: string, message: string) {
  return context.json({ error: code, message }, status);
}

function partSize(env: Env): number {
  const override = Number(env.PART_SIZE_BYTES);
  if (Number.isInteger(override) && override >= MIN_R2_PART_SIZE) return override;
  return DEFAULT_PART_SIZE;
}

function cleanedTitle(value: string): string {
  return value.replace(/[\u0000-\u001F\u007F]/g, "");
}

// The default title is the filename without its extension, so "beach.mov"
// shows as "beach" and downloads as "beach.mp4" rather than "beach.mov.mp4".
function defaultTitle(filename: string): string {
  const cleaned = cleanedTitle(filename).trim();
  const stem = cleaned.replace(/\.[A-Za-z0-9]{1,5}$/, "");
  return stem || cleaned;
}

function validOptionalNumber(value: unknown): value is number | null | undefined {
  return value === null || value === undefined || (typeof value === "number" && Number.isFinite(value));
}

function validOptionalInteger(value: unknown): value is number | null | undefined {
  return value === null || value === undefined || (typeof value === "number" && Number.isInteger(value));
}

function uploadShape(row: VideoRow, env: Env) {
  return { video: toVideo(row, env.PUBLIC_BASE_URL), partSizeBytes: row.part_size_bytes, partCount: row.part_count };
}

async function requireVideo(context: Context<App>): Promise<VideoRow | Response> {
  const id = context.req.param("id");
  if (!id) return error(context, 404, "not_found", "Video not found.");
  const video = await videoById(context.env, id);
  return video ?? error(context, 404, "not_found", "Video not found.");
}

function decodeCursor(value: string): { createdAt: number; id: string } | null {
  try {
    const parsed = JSON.parse(atob(value.replace(/-/g, "+").replace(/_/g, "/")));
    return typeof parsed.createdAt === "number" && typeof parsed.id === "string" ? parsed : null;
  } catch {
    return null;
  }
}

function encodeCursor(row: VideoRow): string {
  return btoa(JSON.stringify({ createdAt: row.created_at, id: row.id })).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export const videos = new Hono<App>();

videos.post("/", async (context) => {
  context.set("route", "create_video");
  let input: Record<string, unknown>;
  try {
    input = await context.req.json();
  } catch {
    return error(context, 400, "invalid_request", "Request body must be JSON.");
  }
  const { idempotencyKey, originalFilename, sizeBytes, durationSeconds, width, height } = input;
  if (typeof idempotencyKey !== "string" || idempotencyKey.length === 0 || typeof originalFilename !== "string" || originalFilename.length === 0) {
    return error(context, 400, "invalid_request", "Required fields are missing or invalid.");
  }
  if (typeof sizeBytes !== "number" || !Number.isInteger(sizeBytes) || sizeBytes <= 0 || sizeBytes > MAX_SIZE) {
    return error(context, 400, "invalid_size", "Size must be between 1 byte and 5 GiB.");
  }
  if (!validOptionalNumber(durationSeconds) || !validOptionalInteger(width) || !validOptionalInteger(height)) {
    return error(context, 400, "invalid_request", "Media metadata is invalid.");
  }

  const existing = await videoByIdempotencyKey(context.env, idempotencyKey);
  if (existing) return context.json(uploadShape(existing, context.env), 200);

  const title = defaultTitle(originalFilename);
  if (!title) return error(context, 400, "invalid_request", "Filename must contain visible characters.");
  const objectKey = randomObjectKey();
  const upload = await context.env.BUCKET.createMultipartUpload(objectKey, { httpMetadata: { contentType: "video/mp4" } });
  const now = Date.now();
  const size = partSize(context.env);
  const row = {
    id: crypto.randomUUID(), objectKey, title, originalFilename, sizeBytes, durationSeconds: durationSeconds ?? null,
    width: width ?? null, height: height ?? null, status: "uploading", uploadId: upload.uploadId,
    partSizeBytes: size, partCount: Math.ceil(sizeBytes / size), shareToken: randomShareToken(), idempotencyKey, createdAt: now
  };
  try {
    await context.env.DB.prepare(`INSERT INTO videos (
      id, object_key, title, original_filename, size_bytes, duration_seconds, width, height, status,
      upload_id, part_size_bytes, part_count, share_token, idempotency_key, created_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`).bind(
      row.id, row.objectKey, row.title, row.originalFilename, row.sizeBytes, row.durationSeconds, row.width, row.height,
      row.status, row.uploadId, row.partSizeBytes, row.partCount, row.shareToken, row.idempotencyKey, row.createdAt
    ).run();
  } catch (cause) {
    await upload.abort();
    const raced = await videoByIdempotencyKey(context.env, idempotencyKey);
    if (raced) return context.json(uploadShape(raced, context.env), 200);
    throw cause;
  }
  const created = await videoById(context.env, row.id);
  if (!created) throw new HTTPException(500);
  return context.json(uploadShape(created, context.env), 201);
});

videos.put("/:id/parts/:partNumber", async (context) => {
  context.set("route", "upload_part");
  const video = await requireVideo(context);
  if (video instanceof Response) return video;
  if (video.status !== "uploading" || !video.upload_id) return error(context, 409, "not_uploading", "Video is not uploading.");
  const partNumber = Number(context.req.param("partNumber"));
  if (!Number.isInteger(partNumber) || partNumber < 1 || partNumber > video.part_count) {
    return error(context, 400, "invalid_part", "Part number is invalid.");
  }
  const expected = partNumber === video.part_count
    ? video.size_bytes - (video.part_count - 1) * video.part_size_bytes
    : video.part_size_bytes;
  const length = context.req.header("Content-Length");
  if (length === undefined || !/^\d+$/.test(length) || Number(length) !== expected) {
    return error(context, 400, "part_size_mismatch", "Part size does not match the expected size.");
  }
  if (!context.req.raw.body) return error(context, 400, "part_size_mismatch", "Part body is required.");
  const multipart = context.env.BUCKET.resumeMultipartUpload(video.object_key, video.upload_id);
  const uploaded = await multipart.uploadPart(partNumber, context.req.raw.body);
  await savePart(context.env, video.id, { partNumber, etag: uploaded.etag });
  return context.json({ partNumber, etag: uploaded.etag, sizeBytes: expected });
});

videos.get("/:id", async (context) => {
  context.set("route", "video_status");
  const video = await requireVideo(context);
  if (video instanceof Response) return video;
  return context.json({ ...uploadShape(video, context.env), uploadedParts: parseParts(video.parts_json).map((part) => part.partNumber) });
});

videos.post("/:id/complete", async (context) => {
  context.set("route", "complete_video");
  const video = await requireVideo(context);
  if (video instanceof Response) return video;
  if (video.status === "ready") {
    const shareUrl = `${context.env.PUBLIC_BASE_URL}/v/${video.share_token}`;
    return context.json({ video: toVideo(video, context.env.PUBLIC_BASE_URL), shareUrl });
  }
  if (video.status !== "uploading" || !video.upload_id) return error(context, 409, "not_uploading", "Video is not uploading.");
  const parts = parseParts(video.parts_json);
  const present = new Set(parts.map((part) => part.partNumber));
  const missing = Array.from({ length: video.part_count }, (_, index) => index + 1).filter((part) => !present.has(part));
  if (missing.length > 0) return context.json({ error: "parts_missing", missing }, 409);
  const multipart = context.env.BUCKET.resumeMultipartUpload(video.object_key, video.upload_id);
  let object: R2Object | null;
  try {
    await multipart.complete(parts);
    object = await context.env.BUCKET.head(video.object_key);
  } catch (cause) {
    object = await context.env.BUCKET.head(video.object_key);
    if (!object) throw cause;
  }
  if (!object || object.size !== video.size_bytes) {
    await context.env.BUCKET.delete(video.object_key);
    await context.env.DB.prepare("UPDATE videos SET status = 'failed', upload_id = NULL WHERE id = ?").bind(video.id).run();
    return error(context, 422, "size_mismatch", "Stored video size does not match.");
  }
  const readyAt = Date.now();
  await context.env.DB.prepare("UPDATE videos SET status = 'ready', upload_id = NULL, ready_at = ? WHERE id = ?").bind(readyAt, video.id).run();
  const ready = await videoById(context.env, video.id);
  if (!ready) throw new HTTPException(500);
  const shareUrl = `${context.env.PUBLIC_BASE_URL}/v/${ready.share_token}`;
  return context.json({ video: toVideo(ready, context.env.PUBLIC_BASE_URL), shareUrl });
});

videos.post("/:id/abort", async (context) => {
  context.set("route", "abort_video");
  const video = await requireVideo(context);
  if (video instanceof Response) return video;
  if (video.status !== "uploading" || !video.upload_id) return error(context, 409, "not_uploading", "Video is not uploading.");
  await context.env.BUCKET.resumeMultipartUpload(video.object_key, video.upload_id).abort();
  await context.env.DB.prepare("DELETE FROM videos WHERE id = ?").bind(video.id).run();
  return context.body(null, 204);
});

videos.get("/", async (context) => {
  context.set("route", "list_videos");
  const limitRaw = context.req.query("limit");
  const limit = limitRaw === undefined ? 50 : Number(limitRaw);
  if (!Number.isInteger(limit) || limit < 1 || limit > 200) return error(context, 400, "invalid_limit", "Limit must be between 1 and 200.");
  const cursorRaw = context.req.query("cursor");
  const cursor = cursorRaw === undefined ? null : decodeCursor(cursorRaw);
  if (cursorRaw !== undefined && !cursor) return error(context, 400, "invalid_cursor", "Cursor is invalid.");
  const query = cursor
    ? context.env.DB.prepare("SELECT * FROM videos WHERE created_at < ? OR (created_at = ? AND id < ?) ORDER BY created_at DESC, id DESC LIMIT ?").bind(cursor.createdAt, cursor.createdAt, cursor.id, limit + 1)
    : context.env.DB.prepare("SELECT * FROM videos ORDER BY created_at DESC, id DESC LIMIT ?").bind(limit + 1);
  const rows = (await query.all<VideoRow>()).results;
  const more = rows.length > limit;
  const page = rows.slice(0, limit);
  return context.json({ videos: page.map((row) => toVideo(row, context.env.PUBLIC_BASE_URL)), nextCursor: more ? encodeCursor(page.at(-1)!) : null });
});

videos.patch("/:id", async (context) => {
  context.set("route", "update_video");
  const video = await requireVideo(context);
  if (video instanceof Response) return video;
  let input: unknown;
  try { input = await context.req.json(); } catch { return error(context, 400, "invalid_request", "Request body must be JSON."); }
  if (!input || typeof input !== "object" || Array.isArray(input)) {
    return error(context, 400, "invalid_request", "Request body must include a title or shareEnabled.");
  }
  const fields = input as Record<string, unknown>;
  const hasTitle = Object.hasOwn(fields, "title");
  const hasShareEnabled = Object.hasOwn(fields, "shareEnabled");
  if (!hasTitle && !hasShareEnabled) return error(context, 400, "invalid_request", "Request body must include a title or shareEnabled.");

  let title: string | undefined;
  if (hasTitle) {
    if (typeof fields.title !== "string") return error(context, 400, "invalid_title", "Title is invalid.");
    title = cleanedTitle(fields.title).trim().slice(0, 200);
    if (!title) return error(context, 400, "invalid_title", "Title must not be empty.");
  }
  if (hasShareEnabled && typeof fields.shareEnabled !== "boolean") {
    return error(context, 400, "invalid_request", "shareEnabled must be a boolean.");
  }
  if (hasShareEnabled && video.status !== "ready") return error(context, 409, "not_ready", "Video is not ready.");

  if (hasTitle && hasShareEnabled) {
    await context.env.DB.prepare("UPDATE videos SET title = ?, share_enabled = ? WHERE id = ?").bind(title!, fields.shareEnabled ? 1 : 0, video.id).run();
  } else if (hasTitle) {
    await context.env.DB.prepare("UPDATE videos SET title = ? WHERE id = ?").bind(title!, video.id).run();
  } else {
    await context.env.DB.prepare("UPDATE videos SET share_enabled = ? WHERE id = ?").bind(fields.shareEnabled ? 1 : 0, video.id).run();
  }
  const updated = await videoById(context.env, video.id);
  if (!updated) throw new HTTPException(500);
  return context.json({ video: toVideo(updated, context.env.PUBLIC_BASE_URL) });
});

videos.post("/:id/revoke", async (context) => {
  context.set("route", "revoke_video");
  const video = await requireVideo(context);
  if (video instanceof Response) return video;
  if (video.status !== "ready") return error(context, 409, "not_ready", "Video is not ready.");
  const token = randomShareToken();
  await context.env.DB.prepare("UPDATE videos SET share_token = ?, share_enabled = 1 WHERE id = ?").bind(token, video.id).run();
  const updated = await videoById(context.env, video.id);
  if (!updated) throw new HTTPException(500);
  const shareUrl = `${context.env.PUBLIC_BASE_URL}/v/${token}`;
  return context.json({ video: toVideo(updated, context.env.PUBLIC_BASE_URL), shareUrl });
});

videos.delete("/:id", async (context) => {
  context.set("route", "delete_video");
  const video = await requireVideo(context);
  if (video instanceof Response) return video;
  if (video.status === "uploading" && video.upload_id) {
    await context.env.BUCKET.resumeMultipartUpload(video.object_key, video.upload_id).abort();
  }
  await context.env.BUCKET.delete(video.object_key);
  await context.env.DB.prepare("DELETE FROM videos WHERE id = ?").bind(video.id).run();
  return context.body(null, 204);
});
