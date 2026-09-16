CREATE TABLE forward_queue (
  scope TEXT NOT NULL, id TEXT NOT NULL, digest TEXT NOT NULL,
  document TEXT NOT NULL, size_bytes INTEGER NOT NULL CHECK(size_bytes > 0),
  admitted_at INTEGER NOT NULL, expires_at INTEGER NOT NULL,
  attempts INTEGER NOT NULL CHECK(attempts >= 0),
  next_attempt_at INTEGER NOT NULL,
  max_attempts INTEGER NOT NULL CHECK(max_attempts > 0),
  status TEXT NOT NULL CHECK(status IN ('pending', 'delivered', 'discarded')),
  outcome TEXT, settled_at INTEGER,
  PRIMARY KEY(scope, id)
) STRICT;
CREATE INDEX forward_queue_due
  ON forward_queue(scope, status, next_attempt_at, admitted_at, id);
PRAGMA user_version = 2;
