# Duplicate Finder

Finds identical files under user chosen folders. Runs after the main walk using the size index collected during scanning, so no second full walk.

## Scope
- Default roots: `~/Downloads`, `~/Desktop`, `~/Documents`, `~/Movies`, `~/Pictures` (not inside photo libraries), `~/Music` (not inside the Music library). Configurable in Settings > Duplicates
- Minimum file size: 1 MB default, slider 100 KB to 1 GB
- Excludes packages, git working trees, `node_modules`, app bundles, anything protected

## Pipeline
1. Size buckets from the walk index: keep buckets with 2 or more files
2. Drop same inode entries (hard links are one file)
3. Partial hash: SHA256 of first 64 KB + last 64 KB + size. Keep buckets with 2 or more equal partial hashes
4. Full hash: streaming SHA256 (`CryptoKit`, 1 MB chunks, `FileHandle` read). Bounded concurrency 4, cancellable between chunks
5. Group equal full hashes into `duplicate_group`
6. Clone check: for every member, compare `privateSize`. Members that are clones of each other contribute ~0 to `reclaimable_size`. Group shows "Already space efficient (APFS clones)" when reclaimable < 5 percent of size
7. Keeper selection (default): the oldest `created` date, tie break shortest path, tie break path not under `~/Downloads`

## API

```swift
public protocol DuplicateFinder: Sendable {
    func find(sizeIndex: SizeIndex, options: DuplicateOptions) -> AsyncThrowingStream<DuplicateEvent, Error>
}
public enum DuplicateEvent: Sendable {
    case hashing(done: Int, total: Int, bytes: Int64)
    case group(DuplicateGroup, members: [Candidate])
    case finished
}
```
Members that are not keepers become `candidate` rows: `category = duplicate`, `tier = yellow`, `rule_id = duplicate.content`, `dup_group_id` set. The keeper is stored only in `duplicate_group.keeper_path`.

## Edge Cases
- File changes during hashing (size or mtime differs from walk): drop it from the group
- Files without read permission: skip, count in summary
- Dataless files: never hashed
- Group where all members are in quarantine already: hidden
- User changes the keeper in the UI: previous keeper becomes a candidate, new keeper is removed from candidates (status `ignored` for this session)
- Quarantining every member of a group is blocked: at least one must remain, UI disables the action

## UI Requirements
- Duplicates screen: groups sorted by reclaimable size, header row shows filename, size, count, reclaimable
- Expanded group lists members with a radio button for Keeper, Reveal in Finder, Quick Look
- Action bar: "Quarantine N duplicates, X GB" acting on all non keepers of selected groups
- Hashing progress shown in the scan HUD as its own phase, and cancellable separately ("Skip duplicates")
