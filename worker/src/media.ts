import type { Env, VideoRow } from "./env";
import { viewerHeaders } from "./headers";
import { hasValidMediaSignature } from "./tokens";
import { unavailable } from "./viewer";

function rangeStartsPastEnd(value: string | null, size: number): boolean {
  const match = value?.trim().match(/^bytes=(\d+)-/i);
  return match !== undefined && match !== null && Number(match[1]) >= size;
}

// R2 reports a suffix range as { suffix } rather than offset and length, and
// Miniflare normalizes it, so both shapes have to produce the same answer.
function resolvedRange(range: R2Range | undefined, size: number): { offset: number; length: number } | null {
  if (!range) return null;
  if ("suffix" in range) {
    const length = Math.min(range.suffix, size);
    return { offset: size - length, length };
  }
  const offset = range.offset ?? 0;
  const length = range.length ?? size - offset;
  return { offset, length };
}

function mediaHeaders(): Headers {
  const headers = viewerHeaders();
  headers.set("Content-Disposition", "inline");
  headers.set("Cross-Origin-Resource-Policy", "same-origin");
  return headers;
}

function responseHeaders(object: R2Object): Headers {
  const headers = mediaHeaders();
  object.writeHttpMetadata(headers);
  headers.set("Content-Type", "video/mp4");
  headers.set("Accept-Ranges", "bytes");
  headers.set("ETag", object.httpEtag);
  return headers;
}

function allowedFetchMetadata(request: Request): boolean {
  const destination = request.headers.get("Sec-Fetch-Dest");
  if (destination && !["video", "audio", "empty"].includes(destination)) return false;
  const site = request.headers.get("Sec-Fetch-Site");
  return !site || site === "same-origin" || site === "none";
}

export async function media(env: Env, request: Request, video: VideoRow): Promise<Response> {
  const url = new URL(request.url);
  if (!allowedFetchMetadata(request) || !await hasValidMediaSignature(env.OWNER_TOKEN_SHA256, video.share_token, url.searchParams.get("s"))) {
    return unavailable(env, request);
  }
  const requestedRange = request.headers.has("Range");
  const rangeHeader = request.headers.get("Range");
  if (rangeHeader && !rangeHeader.includes(",") && rangeStartsPastEnd(rangeHeader, video.size_bytes)) {
    const headers = mediaHeaders();
    headers.set("Content-Range", `bytes */${video.size_bytes}`);
    return new Response(null, { status: 416, headers });
  }
  const object = await env.BUCKET.get(video.object_key, { range: request.headers });
  if (!object) {
    if (requestedRange) {
      const head = await env.BUCKET.head(video.object_key);
      if (head) {
        const headers = mediaHeaders();
        headers.set("Content-Range", `bytes */${head.size}`);
        return new Response(null, { status: 416, headers });
      }
    }
    return unavailable(env, request);
  }

  const headers = responseHeaders(object);
  const range = requestedRange ? resolvedRange(object.range, object.size) : null;
  if (requestedRange && (!range || range.length <= 0)) {
    const headers = mediaHeaders();
    headers.set("Content-Range", `bytes */${object.size}`);
    return new Response(null, { status: 416, headers });
  }
  const contentLength = range ? range.length : object.size;
  headers.set("Content-Length", String(contentLength));
  if (range) headers.set("Content-Range", `bytes ${range.offset}-${range.offset + range.length - 1}/${object.size}`);
  const body = "body" in object ? object.body : null;
  if (request.method === "HEAD") {
    await body?.cancel();
    return new Response(null, { status: range ? 206 : 200, headers });
  }
  return new Response(body, { status: range ? 206 : 200, headers });
}
