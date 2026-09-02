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

export async function viewerPage(env: Env, request: Request, video: VideoRow): Promise<Response> {
  const template = await asset(env, request, "index.html");
  const signature = await mediaSignature(env.OWNER_TOKEN_SHA256, video.share_token);
  const mediaUrl = `/v/${video.share_token}/media?s=${signature}`;
  const html = (await template.text())
    .replaceAll("{{title}}", escapeHtml(video.title))
    .replaceAll("{{mediaUrl}}", mediaUrl);
  const headers = viewerHeaders();
  headers.set("Content-Type", "text/html; charset=utf-8");
  return new Response(html, { headers });
}
