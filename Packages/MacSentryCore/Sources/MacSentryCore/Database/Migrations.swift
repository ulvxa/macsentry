import GRDB

enum Migrations {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: v1)
        }
        migrator.registerMigration("v2") { db in
            try db.execute(sql: v2)
        }
        return migrator
    }

    /// The rule group of the candidate (per app for app caches); nil for rows written before v2 and for non rule candidates.
    static let v2 = """
    ALTER TABLE candidate ADD COLUMN rule_group TEXT;
    """

    static let v1 = """
    CREATE TABLE scan_session (
      id            INTEGER PRIMARY KEY AUTOINCREMENT,
      started_at    REAL NOT NULL,
      finished_at   REAL,
      status        TEXT NOT NULL CHECK (status IN ('running','finished','cancelled','failed')),
      roots_json    TEXT NOT NULL,
      files_visited INTEGER NOT NULL DEFAULT 0,
      bytes_visited INTEGER NOT NULL DEFAULT 0,
      error         TEXT
    );

    CREATE TABLE dir_node (
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
      reason          TEXT NOT NULL,
      cli_command     TEXT,
      app_bundle_id   TEXT,
      logical_size    INTEGER NOT NULL,
      allocated_size  INTEGER NOT NULL,
      freeable_size   INTEGER NOT NULL,
      created_at      REAL,
      modified_at     REAL,
      last_used_at    REAL,
      confidence      TEXT CHECK (confidence IN ('high','medium','low')),
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
      ecosystems_json     TEXT NOT NULL,
      last_commit_at      REAL,
      last_modified_at    REAL NOT NULL,
      has_uncommitted     INTEGER NOT NULL DEFAULT 0,
      artifacts_size      INTEGER NOT NULL
    );

    CREATE TABLE duplicate_group (
      id               INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id       INTEGER NOT NULL REFERENCES scan_session(id) ON DELETE CASCADE,
      content_hash     TEXT NOT NULL,
      file_size        INTEGER NOT NULL,
      member_count     INTEGER NOT NULL,
      reclaimable_size INTEGER NOT NULL,
      keeper_path      TEXT NOT NULL
    );

    CREATE TABLE quarantine_batch (
      id             INTEGER PRIMARY KEY AUTOINCREMENT,
      folder_name    TEXT NOT NULL UNIQUE,
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
      size             INTEGER NOT NULL,
      quarantined_at   REAL NOT NULL,
      status           TEXT NOT NULL CHECK (status IN ('inQuarantine','trashed','restored','missing')),
      trashed_at       REAL,
      trash_path       TEXT
    );
    CREATE INDEX quarantine_entry_status ON quarantine_entry(status);

    CREATE TABLE never_touch (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      pattern    TEXT NOT NULL UNIQUE,
      note       TEXT,
      created_at REAL NOT NULL
    );

    CREATE TABLE ignored_path (
      path       TEXT PRIMARY KEY,
      created_at REAL NOT NULL
    );

    CREATE TABLE disk_sample (
      sampled_at     REAL PRIMARY KEY,
      total_bytes    INTEGER NOT NULL,
      free_bytes     INTEGER NOT NULL,
      important_free INTEGER NOT NULL
    );
    """
}
