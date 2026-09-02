import type { Env, VideoRow } from "./env";
import { viewerHeaders } from "./headers";
import { mediaSignature } from "./tokens";

function escapeHtml(value: string): string {
  return value.replace(/[&<>'"]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", "\"": "&quot;" })[character]!);
}

async function asset(env: Env, request: Request, name: string): Promise<Response> {
  return env.ASSETS.fetch(new Request(new URL(`/${name}`, request.url)));
}

export async function unavailable(env: Env, request: Request): Promise<Response> {
  const response = await asset(env, request, "unavailable.html");
  const headers = viewerHeaders();
  headers.set("Content-Type", response.headers.get("Content-Type") ?? "text/html; charset=utf-8");
  return new Response(response.body, { status: 404, headers });
}

// "Sep 1, 2026 · 0:42". Only the date is shown when the duration is unknown.
function metaLine(video: VideoRow): string {
  const parts: string[] = [];
  const when = video.ready_at ?? video.created_at;
  parts.push(new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric", year: "numeric", timeZone: "UTC" }).format(new Date(when)));
  if (video.duration_seconds && video.duration_seconds > 0) {
    const total = Math.round(video.duration_seconds);
    const hours = Math.floor(total / 3600);
    const minutes = Math.floor((total % 3600) / 60);
    const seconds = total % 60;
    parts.push(hours > 0 ? `${hours}:${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}` : `${minutes}:${String(seconds).padStart(2, "0")}`);
  }
  return parts.join(" · ");
}

export async function homePage(env: Env, request: Request): Promise<Response> {
  const response = await asset(env, request, "home.html");
  const headers = viewerHeaders();
  headers.set("Content-Type", "text/html; charset=utf-8");
  return new Response(response.body, { status: 200, headers });
}

export async function viewerPage(env: Env, request: Request, video: VideoRow): Promise<Response> {
  const template = await asset(env, request, "index.html");
  const signature = await mediaSignature(env.OWNER_TOKEN_SHA256, video.share_token);
  const mediaUrl = `/v/${video.share_token}/media?s=${signature}`;
  const html = (await template.text())
    .replaceAll("{{title}}", escapeHtml(video.title))
    .replaceAll("{{meta}}", escapeHtml(metaLine(video)))
    .replaceAll("{{mediaUrl}}", mediaUrl);
  const headers = viewerHeaders();
  headers.set("Content-Type", "text/html; charset=utf-8");
  return new Response(html, { headers });
}
