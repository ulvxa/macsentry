# Scan Engine and True Size

Walks the disk once, computes honest sizes, builds the treemap tree, and hands every entry to the rule engine, project scanner, orphan detector and duplicate finder.

## Scope
- Default root: `/` on the boot Data volume. Override with `-MacSentryScanRoot` (dev) or Settings > General > Scan roots
- Always excluded roots: `/System`, `/Volumes`, `/dev`, `/private/var/vm`, `/private/var/db`, `/Library/Apple`, `/.Spotlight-V100`, `/.fseventsd`, `/.DocumentRevisions-V100`, `/.MobileBackups`, the quarantine folder
- `/System/Volumes/Data` is skipped because its content is already reached through firmlinks (`/Users`, `/Applications`, `/Library`, `/opt`, `/usr/local`)
- When `-MacSentryScanRoot` is set, `~` in rules, protection patterns and project roots resolves to that root (via `AppEnvironment.homeURL`), so fixtures mirror a real home layout. Code must never call `FileManager.homeDirectoryForCurrentUser` directly
- Never follow symlinks. Never cross devices (compare `st_dev` of each dir with the root)
- Packages (`.app`, `.photoslibrary`, `.vmwarevm`, `.bundle`, `.xcarchive`, any dir with `isPackageKey`) are sized fully but treated as one atomic item for rules

## Data Models

```swift
public struct ScanConfig: Sendable {
    var roots: [URL]
    var excluded: [URL]
    var maxConcurrency: Int = 8
    var treeDepth: Int = 8                 // dir_node persisted down to this depth
    var minTreeNodeSize: Int64 = 10_000_000 // skip tiny dirs in dir_node below depth 3
}

public struct FileEntry: Sendable {        // one per visited item, never persisted wholesale
    let url: URL
    let kind: EntryKind                    // file, folder, package, symlink
    let logicalSize: Int64
    let allocatedSize: Int64
    let privateSize: Int64?                // ATTR_CMNEXT_PRIVATESIZE, files only
    let linkCount: UInt32
    let inode: UInt64
    let flags: UInt32                      // st_flags (SF_DATALESS, UF_IMMUTABLE, etc)
    let created: Date?
    let modified: Date?
    let ownerUID: uid_t
}

public struct SizeInfo: Sendable { let logical, allocated, freeable: Int64 }

public enum ScanEvent: Sendable {
    case started(sessionID: Int64)
    case progress(filesVisited: Int, bytesVisited: Int64, currentPath: String)  // throttled to 10 Hz
    case candidates([Candidate])                                                 // batched
    case phase(ScanPhase)          // walking, evaluatingRules, projects, orphans, duplicates, lastUsed
    case finished(ScanSummary)
}
```

## Service API

```swift
public protocol ScanService: Sendable {
    func scan(config: ScanConfig) -> AsyncThrowingStream<ScanEvent, Error>
}
public protocol FileWalker: Sendable {
    func walk(root: URL, excluded: [URL], visit: @Sendable (FileEntry) async -> WalkDecision) async throws
}
public enum WalkDecision { case descend, skipChildren }   // rule engine can claim a whole folder
public protocol SizeCalculator: Sendable {
    func sizeInfo(for entry: FileEntry) -> SizeInfo
    func aggregate(folder: URL) async throws -> SizeInfo  // for claimed folders
}
public protocol LastUsedResolver: Sendable {
    func lastUsed(for urls: [URL]) async -> [URL: Date]  // Spotlight, candidates only
}
```

`FileWalker` default impl: `getattrlistbulk` on each dir fd, requesting name, objtype, fileid, linkcount, data length, data alloc size, crtime, modtime, flags, owner, and `ATTR_CMNEXT_PRIVATESIZE`. A `FileManager.enumerator` impl exists for tests only.

Pipeline: walker emits entries, `RuleEngine` decides per folder whether it claims it (then `skipChildren` and size it via `aggregate`), otherwise descend. Project, orphan and duplicate passes run after the walk on the collected indexes.

## True Size (freeable)
Shown everywhere instead of Finder size. Rules:
1. Base is `allocatedSize` (handles sparse files like `Docker.raw`)
2. APFS clones: if `privateSize` is available use it as freeable for that file (blocks shared with a clone are not freed)
3. Hard links: a file with `linkCount > 1` counts toward freeable only once per inode within the same candidate, and only if all its links are inside that candidate. Otherwise freeable for it is 0
4. Folder freeable = sum of member freeable after rules 1 to 3
5. Inspector shows all three numbers: Logical, On disk, Will free
6. Global caveat banner when local APFS snapshots exist (`tmutil listlocalsnapshots /`): "Space may return after macOS thins local snapshots"

## Last Used
- Spotlight may be off (`mdutil -s` says "Indexing disabled") or stale, so last used never depends on it. The walker reads `ATTR_CMN_ADDEDTIME` (date added, filesystem-level, free in `getattrlistbulk`) into `FileEntry.added`
- Walk time activity date = max(`modified`, `added`) (`OldLargeRule.activityDate`). Old and Large uses it, so a file copied or moved in recently is not old
- Post-walk, per candidate only: `MDItemCreateWithURL` then `kMDItemLastUsedDate`. Final `last_used_at` = max(Spotlight date, activity date, `modified`); a Spotlight date can only make a file newer
- Reason wording follows the source: `oldLarge` says "not changed" (filesystem dates) and is rewritten to "not opened" only when Spotlight supplied a date
- Folder last used = max of children `modified` (computed during walk) and the folder's own Spotlight date
- Never rely on `st_atime`

## Edge Cases
- Dataless files (`SF_DATALESS`, iCloud or File Provider placeholders): skip and never size, moving them would trigger a download
- `~/Library/Mobile Documents` and `~/Library/CloudStorage`: excluded from candidates entirely
- Permission denied on a dir: record in `ScanSummary.unreadable` with path, continue. If count > 50 and FDA missing, prompt onboarding
- Root owned files the user cannot move: candidate gets `action = flagOnly`, `cli_command = "sudo rm -rf '<path>'"` is NOT generated, instead reason says "Owned by root, remove manually if you are sure"
- Files changing during scan: tolerate ENOENT silently
- Very deep trees (node_modules): iterative walk with explicit stack, no recursion
- Huge single dirs (100k entries): `getattrlistbulk` buffer 256 KB, loop until 0
- Cancel: check `Task.isCancelled` per directory, session status `cancelled`, partial results kept

## UI Requirements
- Scan HUD (see `ui-shell.md`): live files count, bytes, current path truncated middle, phase label, Cancel
- After finish: toast with duration, total reclaimable, unreadable count with "Show" link
