# Database Schema

SQLite via GRDB, file at `~/Library/Application Support/MacSentry/macsentry.sqlite` (override with `-MacSentryDatabasePath`). WAL mode. All timestamps stored as Unix seconds (`REAL`). All sizes in bytes (`INTEGER`). Paths stored as absolute POSIX strings, converted to `URL` at the repository boundary.

Settings live in UserDefaults, not here (see `settings-permissions.md`).

## Migration `v1`

```sql
CREATE TABLE scan_session (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  started_at    REAL NOT NULL,
  finished_at   REAL,
  status        TEXT NOT NULL CHECK (status IN ('running','finished','cancelled','failed')),
  roots_json    TEXT NOT NULL,             -- ["/"] or fixture root
  files_visited INTEGER NOT NULL DEFAULT 0,
  bytes_visited INTEGER NOT NULL DEFAULT 0,
  error         TEXT
);

CREATE TABLE dir_node (                     -- treemap source
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id     INTEGER NOT NULL REFERENCES scan_session(id) ON DELETE CASCADE,
  parent_id      INTEGER REFERENCES dir_node(id) ON DELETE CASCADE,
  path           TEXT NOT NULL,
  name           TEXT NOT NULL,
  depth          INTEGER NOT NULL,
  allocated_size INTEGER NOT NULL,
  file_count     INTEGER NOT NULL
);
CREATE INDEX dir_node_parent ON dir_node(session_id, parent_id);

CREATE TABLE candidate (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id      INTEGER NOT NULL REFERENCES scan_session(id) ON DELETE CASCADE,
  path            TEXT NOT NULL,
  kind            TEXT NOT NULL CHECK (kind IN ('file','folder','package')),
  category        TEXT NOT NULL CHECK (category IN ('devCache','appCache','oldLarge','projectArtifact','orphan','duplicate','flagged')),
  rule_id         TEXT NOT NULL,
  tier            TEXT NOT NULL CHECK (tier IN ('green','yellow','red')),
  action          TEXT NOT NULL CHECK (action IN ('quarantine','flagOnly')),
  reason          TEXT NOT NULL,             -- human sentence shown in inspector
  cli_command     TEXT,                      -- only for flagOnly
  app_bundle_id   TEXT,                      -- owning app, used for appRunning checks
  logical_size    INTEGER NOT NULL,
  allocated_size  INTEGER NOT NULL,
  freeable_size   INTEGER NOT NULL,          -- see scanner.md True Size
  created_at      REAL,
  modified_at     REAL,
  last_used_at    REAL,
  confidence      TEXT CHECK (confidence IN ('high','medium','low')), -- orphans only
  project_id      INTEGER REFERENCES project(id) ON DELETE CASCADE,
  dup_group_id    INTEGER REFERENCES duplicate_group(id) ON DELETE CASCADE,
  status          TEXT NOT NULL DEFAULT 'found' CHECK (status IN ('found','quarantined','trashed','restored','ignored','stale'))
);
CREATE INDEX candidate_session_cat ON candidate(session_id, category);
CREATE UNIQUE INDEX candidate_session_path ON candidate(session_id, path, category);

CREATE TABLE project (
  id                  INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id          INTEGER NOT NULL REFERENCES scan_session(id) ON DELETE CASCADE,
  root_path           TEXT NOT NULL,
  name                TEXT NOT NULL,
  ecosystems_json     TEXT NOT NULL,         -- ["node","python","unity"]
  last_commit_at      REAL,
  last_modified_at    REAL NOT NULL,
  has_uncommitted     INTEGER NOT NULL DEFAULT 0,
  artifacts_size      INTEGER NOT NULL
);

CREATE TABLE duplicate_group (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id       INTEGER NOT NULL REFERENCES scan_session(id) ON DELETE CASCADE,
  content_hash     TEXT NOT NULL,           -- SHA256 hex
  file_size        INTEGER NOT NULL,
  member_count     INTEGER NOT NULL,
  reclaimable_size INTEGER NOT NULL,        -- sum of freeable of non keepers
  keeper_path      TEXT NOT NULL
);

CREATE TABLE quarantine_batch (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  folder_name    TEXT NOT NULL UNIQUE,      -- 2026-10-29_064512
  created_at     REAL NOT NULL,
  dry_run        INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE quarantine_entry (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  batch_id         INTEGER NOT NULL REFERENCES quarantine_batch(id) ON DELETE CASCADE,
  candidate_id     INTEGER REFERENCES candidate(id) ON DELETE SET NULL,
  original_path    TEXT NOT NULL,
  quarantine_path  TEXT NOT NULL,
  kind             TEXT NOT NULL,
  rule_id          TEXT NOT NULL,
  tier             TEXT NOT NULL,
  size             INTEGER NOT NULL,        -- freeable size at move time
  quarantined_at   REAL NOT NULL,
  status           TEXT NOT NULL CHECK (status IN ('inQuarantine','trashed','restored','missing')),
  trashed_at       REAL,
  trash_path       TEXT
);
CREATE INDEX quarantine_entry_status ON quarantine_entry(status);

CREATE TABLE never_touch (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  pattern    TEXT NOT NULL UNIQUE,         -- glob, ~ expanded at match time
  note       TEXT,
  created_at REAL NOT NULL
);

CREATE TABLE ignored_path (                 -- "ignore this item forever" from the UI
  path       TEXT PRIMARY KEY,
  created_at REAL NOT NULL
);

CREATE TABLE disk_sample (
  sampled_at     REAL PRIMARY KEY,
  total_bytes    INTEGER NOT NULL,
  free_bytes     INTEGER NOT NULL,
  important_free INTEGER NOT NULL           -- volumeAvailableCapacityForImportantUsage
);
```

## Retention
- Keep the last 5 `scan_session` rows, cascade delete older ones on new scan start
- `disk_sample` older than 90 days deleted on app launch
- Quarantine tables are never pruned automatically

## Swift Models (Core)
GRDB `Codable, FetchableRecord, PersistableRecord` structs, one per table: `ScanSession`, `DirNode`, `Candidate`, `Project`, `DuplicateGroup`, `QuarantineBatch`, `QuarantineEntry`, `NeverTouchPattern`, `IgnoredPath`, `DiskSample`. Enums (`Category`, `Tier`, `CandidateAction`, `CandidateStatus`, `QuarantineStatus`, `Confidence`) are `String` raw value enums matching the CHECK constraints.

## Repository API

```swift
public protocol CandidateStore: Sendable {
    func latestSession() async throws -> ScanSession?
    func candidates(session: Int64, filter: CandidateFilter) async throws -> [Candidate]
    func totals(session: Int64) async throws -> [Category: CategoryTotal]   // count + freeable
    func observeCandidates(session: Int64, filter: CandidateFilter) -> AsyncThrowingStream<[Candidate], Error> // GRDB ValueObservation
    func setStatus(_ status: CandidateStatus, ids: [Int64]) async throws
    func children(of dirNodeID: Int64?, session: Int64) async throws -> [DirNode]
}

public struct CandidateFilter: Sendable, Equatable {
    var categories: Set<Category>
    var tiers: Set<Tier>
    var minFreeable: Int64          // bytes
    var minAgeDays: Int?            // nil = no age filter
    var ageBasis: AgeBasis          // .lastUsed, .modified, .created
    var statuses: Set<CandidateStatus> = [.found]
    var search: String?
}
```

## Edge Cases
- DB locked or corrupted: rename to `macsentry.sqlite.corrupt-<ts>`, create fresh, show a one time alert. Quarantine manifests on disk are the backup of record
- Writes during a scan happen in batches of 500 rows inside one transaction
- Paths with newlines or invalid UTF8: store via `fileSystemRepresentation` bytes decoded lossily, keep a `path_blob BLOB` fallback if a test proves it necessary
