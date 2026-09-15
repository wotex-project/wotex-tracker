# Service v1 foundation contract

This pins the implementation boundary before storage and listener code. It is
an incremental implementation of WTR.06/07/08, not a product-readiness claim.

## Storage and ownership

The service package uses Exqlite **0.40.0**, its bundled SQLite, and the direct
`Exqlite.Sqlite3` API. No Ecto or database server is involved. A caller explicitly
starts one writer process for a local database; separate connections/processes
are serialized by SQLite `BEGIN IMMEDIATE`. Each unit writes the observation,
deduplication record, versioned domain records, event intents and publication
intent in **one** transaction. The expected per-scope generation is checked
inside that transaction. Readers use a read transaction or immutable historical
generation. Scope generations and sequence cursors are decimal strings, never
browser numbers. Native evidence JSON preserves `1` versus `1.0` and wide
integers. Byte payloads use WTR.01's canonical Base64 envelope.

The internal read port accepts a snapshot generation with its exact event
high-water cursor for a fresh snapshot-to-stream handoff. This also works when
a quiet scope's last event predates retention. Subsequent events still obey
retention. The HTTP layer must bind this pair, principal, scope and issue/expiry
time in its authenticated cursor; raw storage tokens do not grant authority.

Schema version 1 is created transactionally using `PRAGMA user_version`.
Unknown newer schemas fail startup. Migrations may never silently reset data.
WAL, `synchronous=FULL`, foreign keys, a 1,000 ms busy timeout, 1,000-page
auto-checkpoint and a 262,144-page database ceiling are mandatory. Page size is
4,096 bytes. Checkpoint is an explicit administrative operation. Backup uses
SQLite `VACUUM INTO` to a fresh private file, never copies a live main file
without its WAL. Restore occurs offline into a fresh private directory and
must pass SQLite integrity and schema checks before listener startup.

The operator supplies an existing absolute private directory (0700) on a local
filesystem. The store rejects symlinks along the configured path, nonregular
database/sidecar files and multiply linked database files. The database is 0600.
This assumes trusted same-user processes, a trustworthy parent directory and a
filesystem honoring SQLite locking/fsync. It does not provide race-proof
containment against a hostile concurrent same-user filesystem writer. Network
filesystems and physical power-loss durability remain unqualified.

## Transactions, retention and recovery

A mutation has explicit principal, scope, idempotency key, expected generation,
admitted request JSON and receiver time. Idempotency covers principal/scope/key
and the complete type-strict admitted request (including expected generation).
An identical retained operation returns its original committed result; different
content conflicts. A duplicate observation ID with different content conflicts.
An identical observation under a new key may record that operation without a new
generation, event or state transition. This prevents repeated live effects.

Operation outcomes are `not_committed`, `committed` (with generation and separate
publication status), or `unknown`. A lost reply is unknown; clients query the
same operation identity and never automatically retry a physical Action.
Committed results are retained for seven days of explicit receiver time;
expired keys remain tombstones and return `operation_expired`. Expiry cannot
silently permit re-execution. Event cursors expire after seven days; a cursor
outside retained history requires an explicit resnapshot. The first store
retains evidence/history and expired tombstones until explicit operator-managed
offline retention; it rejects at capacity rather than silently deleting linked
evidence. Automatic retention/deletion and backup erasure remain separate work.

Publication intents contain the exact Thing/deployment document and generation.
Publication is a separate effect. Only the latest generation for that Thing may
be attempted. The publisher must reconcile an idempotent remote operation and
conditional generation; unsupported remote conditional writes are explicitly
unavailable. A crash after remote success before local confirmation remains
pending/unknown until reconciliation. Cleanup failure is separate from committed
admission and confirmed publication. No retry can overwrite a newer publication.

## Finite budgets

These are service ceilings, not radio protocol maxima. Operator configuration
may lower them. Enlarging them requires a new qualified contract.

| Resource | Ceiling / behavior |
| --- | --- |
| Request body / prepared transaction | 1 MiB each; reject before JSON parsing |
| Observation | WTR.13 core limits; one per admission transaction |
| Domain records per transaction | 16; 256 KiB per record |
| Events per transaction | 16; 16 KiB per event; public projections only |
| Page / event replay batch | 100 records / 100 events; 4 MiB response ceiling |
| Concurrent requests / streams | 32 / 16 per instance; reject excess |
| Store callers | 32 outstanding reservations; reject before mailbox enqueue |
| Request / SQLite busy deadline | 5,000 ms / 1,000 ms |
| SSE poll / idle reauthorization | 1,000 ms; no per-subscriber event queue |
| SSE write / connection lifetime | 5,000 ms / 300,000 ms; reconnect with cursor |
| Shutdown | 10,000 ms; unacknowledged mutations remain unknown |
| Retained operations / records / events | 100,000 each per database; reject at capacity |
| Main database | 1 GiB; WAL/temp files require additional free space |
| Operation / replay retention | 7 days; expiry explicit; fail closed at row capacity |

Readiness checks actual writable storage separately from liveness and ingress
capabilities. Passive BLE absence is `unsupported`, never a successful empty scan.
No listener defaults to remote binding, no URL credentials, and no unauthenticated
loopback privilege. Only reviewed public projections are eligible for HTTP/SSE;
raw evidence requires a separate scope and a byte-preserving export response.

## Source references

The selected driver and its direct API are described by the
[Exqlite 0.40.0 package](https://hex.pm/packages/exqlite/0.40.0) and
[driver documentation](https://exqlite.hexdocs.pm/0.40.0/Exqlite.Sqlite3.html).
Native source/version and executed platform evidence are recorded with each
acceptance batch. Full-disk tests use SQLite's real page ceiling as well as
injected commit boundaries; these are not physical power-cut tests.
