export const viewerSecurityHeaders = {
  "Cache-Control": "no-store",
  "Content-Security-Policy": "default-src 'none'; media-src 'self'; style-src 'self'; script-src 'self'; img-src 'self'; frame-ancestors 'none'",
  "Referrer-Policy": "no-referrer",
  "X-Content-Type-Options": "nosniff",
  "X-Robots-Tag": "noindex, nofollow, noarchive"
};

export function viewerHeaders(): Headers {
  return new Headers(viewerSecurityHeaders);
}
