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
CREATE TABLE rule_states (
  scope TEXT NOT NULL, kind TEXT NOT NULL, rule_id TEXT NOT NULL,
  state_identity TEXT NOT NULL, document TEXT NOT NULL,
  generation INTEGER NOT NULL CHECK(generation > 0), evaluated_at INTEGER NOT NULL,
  transition_identity TEXT NOT NULL,
  PRIMARY KEY(scope, kind, rule_id)
) STRICT;
CREATE TABLE rule_event_intents (
  scope TEXT NOT NULL, id TEXT NOT NULL, digest TEXT NOT NULL,
  kind TEXT NOT NULL, rule_id TEXT NOT NULL,
  generation INTEGER NOT NULL CHECK(generation > 0), created_at INTEGER NOT NULL,
  document TEXT NOT NULL,
  mode TEXT NOT NULL CHECK(mode IN ('live', 'replay')),
  action TEXT NOT NULL CHECK(action IN ('none', 'prohibited', 'separate_authorization_required')),
  PRIMARY KEY(scope, id)
) STRICT;
CREATE INDEX rule_event_scope ON rule_event_intents(scope, rule_id, generation);
PRAGMA user_version = 6;
PRAGMA application_id = 1465143857;
