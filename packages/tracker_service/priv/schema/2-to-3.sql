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
PRAGMA user_version = 3;
