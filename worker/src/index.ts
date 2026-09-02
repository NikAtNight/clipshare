import { Hono } from "hono";
import { ownerAuth } from "./auth";
import { readyVideoByToken } from "./db";
import type { Env } from "./env";
import { media } from "./media";
import { homePage, unavailable, viewerPage } from "./viewer";
import { videos } from "./videos";

type App = { Bindings: Env; Variables: { route: string } };

function log(method: string, route: string, status: number, durationMs: number): void {
  console.log(JSON.stringify({ method, route, status, durationMs }));
}

const app = new Hono<App>();

app.use("*", async (context, next) => {
  const startedAt = Date.now();
  try {
    await next();
  } finally {
    log(context.req.method, context.get("route") ?? "unknown", context.res.status, Date.now() - startedAt);
  }
});

app.use("/api", ownerAuth);
app.use("/api/*", ownerAuth);
app.route("/api/videos", videos);

app.on(["GET", "HEAD"], "/", (context) => {
  context.set("route", "home_page");
  return homePage(context.env, context.req.raw);
});

app.get("/viewer.css", (context) => {
  context.set("route", "viewer_stylesheet");
  return context.env.ASSETS.fetch(context.req.raw);
});
app.get("/viewer.js", (context) => {
  context.set("route", "viewer_script");
  return context.env.ASSETS.fetch(context.req.raw);
});

// Icons are the only other files served by name; everything else in
// public/ is a template that must stay unreachable.
app.get("/favicon.svg", (context) => {
  context.set("route", "icon");
  return context.env.ASSETS.fetch(context.req.raw);
});
app.get("/favicon.png", (context) => {
  context.set("route", "icon");
  return context.env.ASSETS.fetch(context.req.raw);
});
app.get("/apple-touch-icon.png", (context) => {
  context.set("route", "icon");
  return context.env.ASSETS.fetch(context.req.raw);
});

app.get("/v/:token", async (context) => {
  context.set("route", "viewer_page");
  const video = await readyVideoByToken(context.env, context.req.param("token"));
  return video ? viewerPage(context.env, context.req.raw, video) : unavailable(context.env, context.req.raw);
});

app.on(["GET", "HEAD"], "/v/:token/media", async (context) => {
  context.set("route", "viewer_media");
  const video = await readyVideoByToken(context.env, context.req.param("token"));
  return video ? media(context.env, context.req.raw, video) : unavailable(context.env, context.req.raw);
});

app.notFound(async (context) => {
  if (new URL(context.req.url).pathname.startsWith("/api")) {
    context.set("route", "api_not_found");
    return context.json({ error: "not_found", message: "Route not found." }, 404);
  }
  context.set("route", "viewer_not_found");
  return unavailable(context.env, context.req.raw);
});

app.onError((cause, context) => {
  console.error("request failed", cause instanceof Error ? `${cause.name}: ${cause.message}` : "unknown");
  if (new URL(context.req.url).pathname.startsWith("/api")) {
    return context.json({ error: "internal_error", message: "Request failed." }, 500);
  }
  return unavailable(context.env, context.req.raw);
});

export default app;
