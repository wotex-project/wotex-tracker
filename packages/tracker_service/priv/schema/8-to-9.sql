CREATE TABLE action_intents (
  scope TEXT NOT NULL, principal TEXT NOT NULL, id TEXT NOT NULL,
  digest TEXT NOT NULL, document TEXT NOT NULL, thing_id TEXT NOT NULL,
  thing_generation INTEGER NOT NULL CHECK(thing_generation >= 0),
  admitted_at INTEGER NOT NULL, eligible_at INTEGER NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('pending', 'unknown', 'accepted', 'denied', 'failed')),
  outcome TEXT, claimed_at INTEGER, settled_at INTEGER,
  PRIMARY KEY(scope, principal, id)
) STRICT;
CREATE INDEX action_intents_pending
  ON action_intents(scope, status, eligible_at, admitted_at, id);
PRAGMA user_version = 9;
