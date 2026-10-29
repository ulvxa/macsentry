# MacSentry Build Roadmap

Each phase is one Claude Code session. Do not start a phase until the previous one passes every acceptance criterion. Commit at the end of every phase.

Scope decisions locked for v1:
- Native SwiftUI, macOS 26, personal use (no App Store, no notarization yet, open source later)
- Single volume. Quarantine lives on the same volume so moves are instant renames
- Quarantined items sit until the user acts. Final delete = macOS Trash
- Folders can be quarantined as a unit
- Risky stores (Docker, Ollama, simulators, VMs, iOS backups) are flagged with a copyable CLI command, never moved
- Age and size thresholds are user adjustable in the UI
- In: project graveyard, app aware profiles, orphan detector, true size reporting, safety tiers, never touch list, duplicate finder, disk pressure menu bar
- Out of v1: scheduled scans, undo journal, Time Machine check, CLI companion, export report

---

## Phase 0: Skeleton, Tooling, Database
Docs: `features/database-schema.md`, `features/ui-shell.md` (design tokens section only)

Tasks
- `project.yml` for XcodeGen: app target `MacSentry`, bundle id `dev.macsentry.app`, macOS 26.0, hardened runtime on, App Sandbox OFF, depends on local package `Packages/MacSentryCore`
- `Packages/MacSentryCore` with GRDB dependency, `Database` type that opens `~/Library/Application Support/MacSentry/macsentry.sqlite` and runs migrations `v1`
- `FixtureBuilder` test helper that builds file trees in a temp dir (files with given sizes and dates, folders, symlinks, hard links, clones, sparse files)
- Launch arguments read through `AppEnvironment`: `MacSentryScanRoot`, `MacSentryDryRun`, `MacSentryDatabasePath`
- Empty app window: `NavigationSplitView` with sidebar items from `ui-shell.md`, placeholder detail views, monochrome AccentColor
- `.swiftlint.yml`, `.swiftformat`, `.gitignore` (ignores `*.xcodeproj`, `.build`, `DerivedData`)

Acceptance Criteria
- [ ] `xcodegen generate` then build succeeds with zero warnings
- [ ] `swift test --package-path Packages/MacSentryCore` passes with at least: migration test on an in memory DB, FixtureBuilder test creating a clone and a hard link
- [ ] App launches, shows glass sidebar with all sections, switching sections works
- [ ] Passing `-MacSentryDatabasePath /tmp/x.sqlite` creates the DB there instead of App Support
- [ ] `swiftlint --strict` clean

## Phase 1: Permissions and Protection Policy
Docs: `features/settings-permissions.md`, `features/quarantine.md` (Protection section)

Tasks
- `PermissionService.hasFullDiskAccess()` and onboarding sheet with button that opens the Full Disk Access pane
- `ProtectionPolicy` with built in protected list plus user never touch patterns from DB
- `SettingsStore` (UserDefaults backed) with all keys from `settings-permissions.md`
- Settings window: General, Thresholds, Never Touch, Appearance tabs

Acceptance Criteria
- [ ] Without FDA the onboarding sheet appears on launch, after granting and relaunch it does not
- [ ] Unit tests: every built in protected path returns `.denied`, a user glob `**/ClientWork/**` denies a matching fixture path, `~/MacSentry Quarantine` itself is denied, a path containing `..` that resolves into a protected dir is denied
- [ ] Adding and removing a never touch pattern in Settings persists across relaunch

## Phase 2: Scan Engine and True Size
Docs: `features/scanner.md`

Tasks
- `FileWalker` on `getattrlistbulk` with bounded concurrency, no symlink following, stays on the root device, skips dataless files and excluded roots
- `SizeCalculator` returning logical, allocated, freeable (private) size
- Directory size aggregation into `dir_node` up to depth 8
- `ScanService.scan(config:)` emitting `ScanEvent` stream with progress, cancel support
- `LastUsedResolver` using Spotlight `kMDItemLastUsedDate` for candidates only

Acceptance Criteria
- [ ] Fixture test: 3 files of 1 MB, 10 MB, 100 MB report exact logical sizes and correct folder totals
- [ ] Clone test: a 50 MB file plus its `clonefile` copy reports freeable close to 0 for the clone
- [ ] Hard link test: a file with 2 links inside the scanned tree is counted once in folder totals
- [ ] Sparse test: 1 GB sparse file reports allocated far below logical
- [ ] Symlink to a directory outside the root is not traversed
- [ ] Cancel stops the walk within 1 second and marks the session `cancelled`
- [ ] Scanning a 200k file fixture finishes under 20 s on Apple Silicon (perf test, skippable in CI)

## Phase 3: Rules Engine, App Inventory, Safety Tiers
Docs: `features/rules-engine.md`

Tasks
- `Rule` model decoded from `Resources/Rules/*.json`, catalog seeded from the table in `rules-engine.md`
- `AppInventory` listing installed apps (bundle id, name, version, path) and running state
- `RuleEngine` producing `Candidate` rows with tier, reason, action (`quarantine` or `flagOnly`), CLI command
- `OldLargeRule` driven by the user thresholds (age days, min size, age basis)
- Rules only activate when their app is installed or their path exists

Acceptance Criteria
- [ ] Every JSON rule decodes, unknown keys fail the test
- [ ] Fixture with fake `~/Library/Developer/Xcode/DerivedData` produces a green `devCache` candidate
- [ ] Fixture `Docker.raw` path produces `flagOnly` with the docker command, never `quarantine`
- [ ] Changing min size from 500 MB to 5 GB in settings removes smaller old/large candidates on rescan
- [ ] Rule for an app that is not installed and whose path does not exist is skipped (verified via test double inventory)

## Phase 4: Main UI
Docs: `features/ui-shell.md`

Tasks
- Overview: disk bar, category cards, scan button, scan HUD, treemap
- Category list screens with Table, filters (age slider, size slider, tier), multi select, glass action bar
- Inspector panel, Reveal in Finder, Quick Look, copy CLI command
- Flagged screen listing all `flagOnly` candidates with commands

Acceptance Criteria
- [ ] Full scan of a fixture root populates every sidebar section with correct counts
- [ ] Moving the age slider filters the table live without rescanning
- [ ] Treemap drill down and breadcrumb back work, clicking a tile selects the item in its list
- [ ] Space opens Quick Look on the selected row, Cmd R starts a scan, Esc cancels
- [ ] With Reduce Transparency enabled the UI stays readable (system handles glass fallback)
- [ ] All screens usable at the minimum window size 960x620

## Phase 5: Quarantine, Trash, Restore
Docs: `features/quarantine.md`

Tasks
- `QuarantineService.quarantine`, `.trash`, `.restore`, `.list`
- Batch folders with mirrored paths plus `manifest.json`
- Quarantine screen with batches, totals, Move to Trash, Restore, Reveal
- Pending space banner: in quarantine vs in Trash vs actually freed

Acceptance Criteria
- [ ] Quarantining a fixture folder moves it (same inode, verified) to `<root>/MacSentry Quarantine/<batch>/<mirrored path>`
- [ ] Manifest JSON lists every item with original path, size, rule id
- [ ] Item deleted between scan and quarantine fails gracefully with reason `missing`, others in the batch succeed
- [ ] Protected path in a batch is refused with reason `protected`, never moved
- [ ] Owning app running blocks the move with reason `appRunning`
- [ ] Move to Trash puts items in `~/.Trash`, DB status becomes `trashed`
- [ ] Restore puts the item back at its original path, refuses if something now exists there
- [ ] With `-MacSentryDryRun YES` nothing moves on disk, UI shows a dry run badge
- [ ] Grep proves no `removeItem` call in the codebase

## Phase 6: Project Graveyard
Docs: `features/project-graveyard.md`

Acceptance Criteria
- [ ] Fixture with a git repo containing `node_modules` and `.venv` detects the project, both artifacts, and last commit date
- [ ] Source files are never candidates, only artifact folders
- [ ] Nested `node_modules` inside `node_modules` counted once
- [ ] Uncommitted changes badge shows for a dirty fixture repo
- [ ] Quarantining artifacts of one project leaves its `.git` and source untouched

## Phase 7: Orphans and Duplicates
Docs: `features/orphan-detector.md`, `features/duplicate-finder.md`

Acceptance Criteria
- [ ] Fixture `~/Library/Application Support/com.fake.deletedapp` with no installed app is an orphan with `high` confidence
- [ ] Folder belonging to an installed test double app is not an orphan
- [ ] `com.apple.*` and allowlisted system folders are never orphans
- [ ] Three identical 20 MB files form one duplicate group, one keeper preselected
- [ ] A clone pair is grouped but shows reclaimable near 0
- [ ] Hard links to the same inode are not reported as duplicates
- [ ] Duplicate hashing of 5 GB fixture can be cancelled

## Phase 8: Menu Bar and Disk Pressure
Docs: `features/menu-bar.md`

Acceptance Criteria
- [ ] Menu bar extra shows free space, 30 day sparkline, quarantine total, Scan and Open buttons
- [ ] Closing the main window keeps the app alive in the menu bar
- [ ] A free space sample is stored every 15 minutes while running
- [ ] Notification fires once when free space crosses below the threshold, not again until it recovers
- [ ] Launch at login toggle works via `SMAppService`

## Phase 9: Hardening and Real Machine Dry Run
Tasks
- Run a real scan of `/` with `-MacSentryDryRun YES` and review results manually
- Fix false positives, verify every `verify: true` path in the rule catalog against the real machine
- Performance pass with Instruments, memory under 400 MB during a full scan

Acceptance Criteria
- [ ] Full real scan completes without crash, no protected path appears as a candidate
- [ ] All rule catalog entries marked `verify` are confirmed or removed
- [ ] Quarantine then trash then empty Trash on 3 real green items frees the expected space
