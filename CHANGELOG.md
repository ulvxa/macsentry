# Changelog

All notable changes to MacSentry are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-10-30

First public release.

### Added
- **Scan engine**: a single pass with `getattrlistbulk` and bounded concurrency. It never follows symlinks, stays on the root volume, and can be cancelled. Sizes are reported as logical, allocated and freeable, so APFS clones, hard links and sparse files are counted correctly.
- **Rule catalog** stored as JSON, with app-aware profiles that turn on when the app is installed or its folder exists. It covers Xcode, Android Studio, Unity, Docker, Ollama, VMware Fusion, Node, Python, Rust, Go, Swift, Ruby, Homebrew, Adobe, DaVinci Resolve, Blender, VS Code, Chrome, Spotify, Steam, Telegram, iOS backups and more.
- **Safety tiers**: Safe, Rebuildable and Careful (`green`, `yellow`, `red` in rule JSON), told apart by glyph and label. Only Safe items are preselected.
- **Dev Caches** and **App Caches**, grouped per app. Nested Chromium and Electron caches, `~/Library/Caches`, sandboxed container caches and updater downloads are attributed to their apps.
- **Old and Large**: adjustable age and size thresholds. Age is the newest of the Spotlight last-used date, the modified date and the date added. Files over a large-file size are listed whatever their age, and old installers in Downloads are included.
- **Projects** graveyard: finds idle code projects and their rebuildable artifacts (`node_modules`, `.venv`, `target`, `DerivedData`, `.build`, `Pods`, Unity `Library`, ...). It shows the last commit date and a badge for uncommitted changes. Source code and `.git` are never candidates.
- **Orphans**: `~/Library` leftovers from uninstalled apps and settings folders from older app versions, each with a confidence level. Installed CLI tools and SDKs are recognized so their data is not reported.
- **Duplicates**: content matched by SHA-256 using a partial hash first, then a full hash. APFS clones are recognized, hard links are ignored, a keeper is preselected, and you cannot quarantine every copy.
- **Flagged**: Docker, Ollama, simulators, Android SDK images, VMs, Steam games and iOS backups are listed with a CLI command you can copy, and are never moved.
- **Quarantine**: picked items move on the same volume to `~/MacSentry Quarantine/<batch>/`, keeping their original folder structure. Each batch records a `manifest.json` and a `journal.jsonl`. You can restore items or move them to the Trash. Each move is checked again for protection, missing items, changes since the scan, a running owning app and locked files.
- **ProtectionPolicy**: built-in deny list (system, apps, credentials, keychains, Mail, Messages, iCloud, wallets, photo and music libraries, git working trees) plus user never-touch patterns and ignored items.
- **Overview**: disk usage bar, category cards, scan HUD and a treemap with drill down.
- **Menu bar** disk-pressure panel: free space, 30-day sparkline, quarantine and Trash totals, low disk space notification, and launch at login.
- **Settings**: General, Thresholds, Never Touch, Ignored, Profiles, Projects, Duplicates, Notifications and Appearance.
- Full Disk Access onboarding with a limited scan mode.
- `MacSentry Dev` scheme with a fixture home and dry run mode.
- `scripts/make-dmg.sh` to build a release DMG.

### Notes
- Requires macOS 26 on Apple Silicon.
- The build is not notarized yet. On first launch, right-click the app and choose Open.

[0.1.0]: https://github.com/ulvxa/macsentry/releases/tag/v0.1.0
