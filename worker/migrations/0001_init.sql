CREATE TABLE videos (
  id TEXT PRIMARY KEY,
  object_key TEXT NOT NULL UNIQUE,
  title TEXT NOT NULL,
  original_filename TEXT NOT NULL,
  size_bytes INTEGER NOT NULL,
  duration_seconds REAL,
  width INTEGER,
  height INTEGER,
  status TEXT NOT NULL CHECK (status IN ('uploading', 'ready', 'failed')),
  upload_id TEXT,
  part_size_bytes INTEGER NOT NULL,
  part_count INTEGER NOT NULL,
  parts_json TEXT NOT NULL DEFAULT '[]',
  share_token TEXT NOT NULL UNIQUE,
  idempotency_key TEXT UNIQUE,
  created_at INTEGER NOT NULL,
  ready_at INTEGER
);
CREATE INDEX videos_created_at ON videos (created_at DESC);
