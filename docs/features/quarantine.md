# Quarantine, Trash, Restore, Protection

The only part of the app that changes the disk. Two operations exist: move into quarantine (rename on the same volume) and move from quarantine to the macOS Trash. Restore is a move back. Nothing is ever unlinked by MacSentry.

## Quarantine Folder
- Location: `~/MacSentry Quarantine/` (visible in Finder on purpose so the user can inspect it)
- On creation: write `.metadata_never_index`, set `isExcludedFromBackupKey = true` on the folder, add a `README.txt` explaining what the folder is
- Layout: one folder per batch, original path mirrored inside it

```
~/MacSentry Quarantine/
  README.txt
  2026-10-29_064512/
    manifest.json
    journal.jsonl
    Users/ulvi/Library/Developer/Xcode/DerivedData/
    Users/ulvi/Library/Caches/Homebrew/
```

## manifest.json (written atomically, updated on every status change)
```json
{
  "version": 1,
  "batch": "2026-10-29_064512",
  "createdAt": "2026-10-29T06:45:12+01:00",
  "dryRun": false,
  "entries": [
    {
      "originalPath": "/Users/ulvi/Library/Caches/Homebrew",
      "quarantinePath": "/Users/ulvi/MacSentry Quarantine/2026-10-29_064512/Users/ulvi/Library/Caches/Homebrew",
      "kind": "folder",
      "ruleId": "homebrew.cache",
      "tier": "green",
      "size": 4831838208,
      "status": "inQuarantine"
    }
  ]
}
```
`journal.jsonl` gets one appended line per entry status change, and reconcile replays it on top of the manifest, so changes made after the last manifest flush survive a crash. Dry run batches write no journal.

The manifest is the source of truth if the DB is lost. On launch, `QuarantineService.reconcile()` rebuilds `quarantine_entry` rows from manifests and marks entries whose files vanished as `missing`.

## API

```swift
public protocol QuarantineService: Sendable {
    func quarantine(_ candidates: [Candidate]) async -> QuarantineResult
    func trash(_ entryIDs: [Int64]) async -> TrashResult
    func restore(_ entryIDs: [Int64]) async -> RestoreResult
    func list() async throws -> [QuarantineBatchSummary]
    func totals() async throws -> QuarantineTotals   // inQuarantine bytes, trashed bytes still in ~/.Trash
    func reconcile() async throws
}

public struct QuarantineResult: Sendable {
    let batchID: Int64?
    let moved: [QuarantineEntry]
    let failed: [(path: URL, reason: MoveFailure)]
}

public enum MoveFailure: String, Error, Sendable {
    case protected, missing, appRunning, permissionDenied, locked, changedSinceScan,
         destinationExists, crossDevice, dataless, unknown
}
```

## Quarantine Algorithm (per item, sequential within a batch)
1. `ProtectionPolicy.check(url)`; denied → `protected`
2. `lstat` again; missing → `missing`, mark candidate `stale`
3. If `allocated` changed more than 10 percent or became a symlink → `changedSinceScan`
4. If candidate `app_bundle_id` app is running → `appRunning`
5. `UF_IMMUTABLE` or `SF_IMMUTABLE` flag → `locked`
6. Compute destination `<batch>/<originalPath without leading slash>`, create intermediate dirs
7. `rename(2)` via `FileManager.moveItem`. `EXDEV` → `crossDevice` (never fall back to copy). `EACCES/EPERM` → `permissionDenied`
8. Insert `quarantine_entry`, append to manifest, set candidate status `quarantined`
9. Dry run: skip step 7, still record with `dry_run = 1` batch, UI shows Dry Run badge. Dry run batches cannot really be trashed: the actions read "Simulate Move to Trash" / "Mark as Trashed" and only change status

## Trash
- `FileManager.trashItem(at:resultingItemURL:)` on the quarantine path, store `trash_path`
- After a batch is fully trashed or restored, remove the now empty mirrored dirs using `rmdir(2)` only (fails on non empty, which is the safety we want) and trash the batch folder including its manifest
- UI never offers Empty Trash. It shows "X GB is in the Trash, empty it to free space" with a button that opens the Trash in Finder

## Restore
- The original path is checked against `ProtectionPolicy` again (`protected` otherwise); the quarantine path must resolve inside its batch folder and not be a symlink (`outsideQuarantine`); the running MacSentry bundle is never moved
- Destination must not exist (`destinationExists` otherwise), parent dirs recreated with original permissions not tracked (acceptable for caches)
- Restore of an item already trashed is not supported in v1, UI shows "Restore from Trash using Finder Put Back"

## Protection Policy

```swift
public protocol ProtectionPolicy: Sendable {
    func check(_ url: URL) -> ProtectionVerdict
}
public enum ProtectionVerdict: Sendable, Equatable { case allowed, denied(String) }
```

Built in denies (path prefix after `standardizedFileURL` and `resolvingSymlinksInPath` of the parent):
- `/System`, `/bin`, `/sbin`, `/usr` (except `/usr/local`), `/private/var`, `/private/etc`, `/Library/Apple`, `/Library/Keychains`
- `/Applications/*.app` and `~/Applications/*.app` (apps are flagOnly, uninstall elsewhere)
- `~/Library/Keychains`, `~/Library/Mail` (except Mail Downloads rule), `~/Library/Messages`, `~/Library/Mobile Documents`, `~/Library/CloudStorage`, `~/Library/Accounts`, `~/Library/Cookies`, `~/Library/LaunchAgents`, `~/Library/Preferences/*.plist` of installed apps
- `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.config/gcloud`, `~/.kube`, `~/.docker/config.json`
- Crypto wallets: `~/Library/Application Support/Ledger Live`, any path containing `wallet` under Application Support (deny, user can override with an explicit allow in v2)
- Any `.git` directory and any path inside a git working tree that is not a known artifact folder
- `*.photoslibrary`, `~/Music/Music`, `~/Pictures/Photos Library.photoslibrary`
- The quarantine folder itself and the app database folder
- The home folder itself, every top level home folder itself (`~/Documents`, `~/Desktop`, `~/Downloads`), and `/`
- User `never_touch` globs (`*`, `**`, `?` supported, `~` expanded)
- `ignored_path` entries

The scanner applies the same policy to hide candidates, and `QuarantineService` checks again before every move. Both must use the same instance.

## Edge Cases
- Same original path quarantined in two batches (restored in between): allowed, separate batch folders
- Quarantine folder deleted by the user in Finder: `reconcile` marks entries `missing`, no crash
- User manually moves something out of quarantine: `reconcile` marks `missing`
- Batch with 10k items: progress reported per item, manifest flushed every 100 items and at end
- Very long mirrored paths beyond `PATH_MAX`: fail item with `unknown`, log it
- App quits while a batch is running: manifest written per flush keeps state recoverable

## UI Requirements
- Quarantine screen: list of batches (date, item count, size, tiers summary), expandable to entries with original path
- Actions per selection: Move to Trash (destructive role), Restore, Reveal in Finder, Quick Look
- Top banner with three numbers: In quarantine, In Trash, Freed this month (sum of entries whose `trash_path` no longer exists)
- Confirmation sheet before Move to Trash listing count and size, default button is Cancel
- Failure sheet after a quarantine batch listing failed items grouped by reason with a human message each
