import type { Env, Part, VideoRow } from "./env";

export function parseParts(value: string): Part[] {
  try {
    const parsed: unknown = JSON.parse(value);
    if (!Array.isArray(parsed)) return [];
    return parsed
      .filter((part): part is Part => typeof part?.partNumber === "number" && typeof part?.etag === "string")
      .sort((left, right) => left.partNumber - right.partNumber);
  } catch {
    return [];
  }
}

export async function videoById(env: Env, id: string): Promise<VideoRow | null> {
  return env.DB.prepare("SELECT * FROM videos WHERE id = ?").bind(id).first<VideoRow>();
}

export async function videoByIdempotencyKey(env: Env, key: string): Promise<VideoRow | null> {
  return env.DB.prepare("SELECT * FROM videos WHERE idempotency_key = ?").bind(key).first<VideoRow>();
}

export async function readyVideoByToken(env: Env, token: string): Promise<VideoRow | null> {
  return env.DB.prepare("SELECT * FROM videos WHERE share_token = ? AND status = 'ready'").bind(token).first<VideoRow>();
}

export async function savePart(env: Env, id: string, part: Part): Promise<void> {
  for (let attempt = 0; attempt < 12; attempt += 1) {
    const video = await videoById(env, id);
    if (!video) throw new Error("video disappeared while saving part");
    const parts = parseParts(video.parts_json).filter((item) => item.partNumber !== part.partNumber);
    parts.push(part);
    parts.sort((left, right) => left.partNumber - right.partNumber);
    const partsJson = JSON.stringify(parts);
    const result = await env.DB.prepare(
      "UPDATE videos SET parts_json = ? WHERE id = ? AND parts_json = ?"
    ).bind(partsJson, id, video.parts_json).run();
    if (result.meta.changes === 1) return;
  }
  throw new Error("could not save upload part");
}

export function toVideo(row: VideoRow, publicBaseUrl: string) {
  return {
    id: row.id,
    title: row.title,
    originalFilename: row.original_filename,
    sizeBytes: row.size_bytes,
    durationSeconds: row.duration_seconds,
    width: row.width,
    height: row.height,
    status: row.status,
    shareUrl: row.status === "ready" ? `${publicBaseUrl}/v/${row.share_token}` : null,
    createdAt: new Date(row.created_at).toISOString(),
    readyAt: row.ready_at === null ? null : new Date(row.ready_at).toISOString()
  };
}
