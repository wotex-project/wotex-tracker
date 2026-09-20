CREATE TABLE access_audit (
  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  scope TEXT NOT NULL, credential_id TEXT NOT NULL, principal TEXT NOT NULL,
  permission TEXT NOT NULL, activity TEXT NOT NULL, occurred_at INTEGER NOT NULL
) STRICT;
CREATE INDEX access_audit_scope ON access_audit(scope, sequence);
CREATE TABLE access_audit_state (
  scope TEXT PRIMARY KEY, coverage_started_at INTEGER NOT NULL,
  truncated INTEGER NOT NULL CHECK(truncated IN (0, 1))
) STRICT;
PRAGMA user_version = 8;
