export interface Env {
  ASSETS: Fetcher;
  BUCKET: R2Bucket;
  DB: D1Database;
  OWNER_TOKEN_SHA256: string;
  PART_SIZE_BYTES?: string;
  PUBLIC_BASE_URL: string;
}

export interface Part {
  etag: string;
  partNumber: number;
}

export interface VideoRow {
  created_at: number;
  duration_seconds: number | null;
  height: number | null;
  id: string;
  idempotency_key: string | null;
  object_key: string;
  original_filename: string;
  part_count: number;
  part_size_bytes: number;
  parts_json: string;
  ready_at: number | null;
  share_enabled: number;
  share_token: string;
  size_bytes: number;
  status: "uploading" | "ready" | "failed";
  title: string;
  upload_id: string | null;
  width: number | null;
}
