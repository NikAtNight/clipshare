export function randomShareToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return bytesToBase64url(bytes);
}

export function randomObjectKey(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  return `videos/${[...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("")}.mp4`;
}

export function bytesToBase64url(bytes: Uint8Array): string {
  let value = "";
  for (const byte of bytes) value += String.fromCharCode(byte);
  return btoa(value).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64urlToBytes(value: string): Uint8Array | null {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) return null;
  try {
    const base64 = value.replace(/-/g, "+").replace(/_/g, "/");
    const decoded = atob(base64.padEnd(base64.length + ((4 - base64.length % 4) % 4), "="));
    return Uint8Array.from(decoded, (character) => character.charCodeAt(0));
  } catch {
    return null;
  }
}

async function mediaSigningKey(secret: string): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
}

// The signature covers only the share token, so a media URL lives exactly as
// long as the link it belongs to and dies with it on revoke.
export async function mediaSignature(secret: string, token: string): Promise<string> {
  const signature = await crypto.subtle.sign("HMAC", await mediaSigningKey(secret), new TextEncoder().encode(token));
  return bytesToBase64url(new Uint8Array(signature));
}

function timingSafeEqual(left: Uint8Array, right: Uint8Array): boolean {
  const sameLength = left.byteLength === right.byteLength;
  const comparisonTarget = sameLength ? right : left;
  const subtle = crypto.subtle as SubtleCrypto & { timingSafeEqual(left: BufferSource, right: BufferSource): boolean };
  return subtle.timingSafeEqual(left, comparisonTarget) && sameLength;
}

export async function hasValidMediaSignature(secret: string, token: string, signature: string | null): Promise<boolean> {
  if (!signature) return false;
  const supplied = base64urlToBytes(signature);
  if (!supplied) return false;
  const expected = base64urlToBytes(await mediaSignature(secret, token));
  return expected !== null && timingSafeEqual(supplied, expected);
}
