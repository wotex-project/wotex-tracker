CREATE TABLE scopes (scope TEXT PRIMARY KEY, generation INTEGER NOT NULL CHECK(generation >= 0)) STRICT;
CREATE TABLE operations (
  scope TEXT NOT NULL, principal TEXT NOT NULL, id TEXT NOT NULL,
  digest TEXT NOT NULL, result TEXT NOT NULL, expires_at INTEGER NOT NULL,
  PRIMARY KEY(scope, principal, id)
) STRICT;
CREATE TABLE observations (
  scope TEXT NOT NULL, id TEXT NOT NULL, digest TEXT NOT NULL,
  generation INTEGER NOT NULL, document TEXT NOT NULL,
  PRIMARY KEY(scope, id)
) STRICT;
CREATE TABLE records (
  scope TEXT NOT NULL, kind TEXT NOT NULL, id TEXT NOT NULL,
  generation INTEGER NOT NULL, document TEXT NOT NULL,
  PRIMARY KEY(scope, kind, id, generation)
) STRICT;
CREATE TABLE events (
  sequence INTEGER PRIMARY KEY AUTOINCREMENT, scope TEXT NOT NULL,
  generation INTEGER NOT NULL, created_at INTEGER NOT NULL, document TEXT NOT NULL
) STRICT;
CREATE INDEX events_scope ON events(scope, sequence);
CREATE TABLE publications (
  scope TEXT NOT NULL, thing_id TEXT NOT NULL, generation INTEGER NOT NULL,
  operation_id TEXT NOT NULL, document TEXT NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('pending', 'published', 'superseded')),
  cleanup TEXT NOT NULL CHECK(cleanup IN ('pending', 'complete', 'failed')),
  PRIMARY KEY(scope, thing_id, generation)
) STRICT;
PRAGMA user_version = 1;
PRAGMA application_id = 1465143857;
