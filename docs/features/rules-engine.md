# Rules Engine, App Aware Profiles, Safety Tiers

Rules are data, not code. Each rule is a JSON object in `Resources/Rules/<group>.json`. The engine matches walker entries against rules and emits `Candidate` rows.

## Safety Tiers
| Tier | Meaning | Glyph (SF Symbol) | Default selected for quarantine |
|---|---|---|---|
| green | Regenerates automatically, zero effort | `checkmark.circle` | yes |
| yellow | Rebuildable but costs time or bandwidth (reimport, redownload, rebuild) | `arrow.triangle.2.circlepath.circle` | no |
| red | Your data or hard to recover, review every item | `exclamationmark.octagon` | no |

UI is monochrome, so tiers are told apart by glyph shape and label, never by color.

## Data Models

```swift
public struct Rule: Codable, Sendable, Identifiable {
    let id: String                   // "xcode.derivedData"
    let group: String                // "Xcode"
    let category: Category           // devCache, appCache, flagged, oldLarge
    let tier: Tier
    let action: CandidateAction      // quarantine | flagOnly
    let match: Match
    let appBundleIDs: [String]       // profile activation + appRunning check
    let requiresAppQuit: Bool
    let reason: String               // shown in inspector
    let cliCommand: String?          // flagOnly only, may contain {path}
    let verify: Bool                 // path not yet confirmed on a real machine
}

public struct Match: Codable, Sendable {
    let paths: [String]?             // exact paths with ~ and * (single segment glob)
    let dirName: String?             // folder name anywhere, e.g. "node_modules" (project rules only)
    let siblingMarker: String?       // file that must exist next to dirName, e.g. "package.json"
    let extensions: [String]?        // for file rules
    let minAgeDays: Int?             // rule specific minimum, user threshold still applies on top
    let claimWholeFolder: Bool       // true = one candidate for the folder, stop descending
    let installedAppFolder: InstalledAppFolder?  // one literal rule per installed app under App Support or Caches
    let subpaths: [String]?          // with installedAppFolder
    let appScope: AppScope?          // app owned folders below a Library root, see App Scope below
}

public struct AppScope: Codable, Sendable {
    let root: String                 // literal, e.g. "~/Library/Application Support"
    let names: [String]?             // folder names or short relative paths ending the match; nil = <root>/<top> itself
    let maxDepth: Int?               // deepest the match may sit below <root>/<top> (required with names)
    let childMarker: String?         // child that must exist inside the match, e.g. "Cache_Data"
    let topNames: [String]?          // glob filter on <top>, e.g. "*-updater"
    let excludeTopPrefixes: [String]?   // e.g. "com.apple."
    let excludeTopNames: [String]?   // skip these <top> names (and `<name>.*`)
    let vendorFolders: Bool?         // also attribute <top>/<second> (Google/Chrome, BraveSoftware/Brave-Browser)
    let unattributedTier: Tier?      // tier when no installed app owns <top> (libraryFallback: yellow, not preselected)
    let unattributedReason: String?  // reason when no installed app owns <top>; says the owner is unknown, quit it first
}
```

## API

```swift
public protocol RuleEngine: Sendable {
    func activeRules(inventory: [InstalledApp], existingPaths: (String) -> Bool) -> [Rule]
    func evaluate(_ entry: FileEntry, rules: [Rule], thresholds: Thresholds) -> RuleMatch?
}
public struct RuleMatch: Sendable { let rule: Rule; let claimsFolder: Bool }
public struct Thresholds: Sendable {
    var minAgeDays: Int        // UI slider, default 180
    var minSize: Int64         // UI slider, default 500 MB
    var ageBasis: AgeBasis     // lastUsed (default), modified, created
}

public protocol AppInventory: Sendable {
    func installedApps() async -> [InstalledApp]       // /Applications, /Applications/Utilities, ~/Applications, Unity Hub editors
    func isRunning(bundleID: String) -> Bool          // NSWorkspace.runningApplications
}
public struct InstalledApp: Sendable, Hashable { let bundleID: String; let name: String; let version: String?; let url: URL }
```

## Activation (App Aware Profiles)
A rule is active if any of its `appBundleIDs` is installed, OR any of its `paths` exists on disk (leftovers still count). Rules with empty `appBundleIDs` are always active. Settings > Profiles shows each group with an on/off toggle and the detected app version.

## Old and Large Rule
Built in, not JSON. Applies to files and packages anywhere under the user home not already claimed by another rule:
- size `freeable >= thresholds.minSize` AND age by `thresholds.ageBasis >= thresholds.minAgeDays`
- tier: red by default. Yellow for installer types `dmg, pkg, xip, iso, zip` in `~/Downloads`
- category `oldLarge`
- excludes `~/Pictures/*.photoslibrary`, `~/Music/Music`, anything under a git repo working tree (handled by graveyard), mail and messages stores

## Rule Catalog (seed v1)
`Q` = quarantine, `F` = flagOnly. `~` = user home. Paths marked `verify` must be checked on the real machine in Phase 9.

### Xcode (`com.apple.dt.Xcode`)
| id | path | tier | act | notes |
|---|---|---|---|---|
| xcode.derivedData | `~/Library/Developer/Xcode/DerivedData` | green | Q | claim whole folder, quit Xcode |
| xcode.deviceSupport | `~/Library/Developer/Xcode/*DeviceSupport/*` | yellow | Q | per version folder, re copied when device connects |
| xcode.previews | `~/Library/Developer/Xcode/UserData/Previews` | green | Q | |
| xcode.cache | `~/Library/Caches/com.apple.dt.Xcode` | green | Q | |
| xcode.archives | `~/Library/Developer/Xcode/Archives/*` | red | Q | contains dSYMs of shipped builds |
| xcode.simCaches | `~/Library/Developer/CoreSimulator/Caches` | green | Q | |
| xcode.simDevices | `~/Library/Developer/CoreSimulator/Devices` | yellow | F | `xcrun simctl delete unavailable` |
| xcode.simRuntimes | `/Library/Developer/CoreSimulator/Volumes` | yellow | F | `xcrun simctl runtime list` then `xcrun simctl runtime delete <id>` |
| xcode.xip | `~/Downloads/Xcode*.xip` | yellow | Q | |

### Android Studio (`com.google.android.studio`)
| id | path | tier | act | notes |
|---|---|---|---|---|
| android.gradleCaches | `~/.gradle/caches` | yellow | Q | quit Studio and gradle daemons |
| android.gradleDists | `~/.gradle/wrapper/dists/*` | yellow | Q | per distribution |
| android.studioCaches | `~/Library/Caches/Google/AndroidStudio*` | green | Q | |
| android.studioLogs | `~/Library/Logs/Google/AndroidStudio*` | green | Q | |
| android.oldStudioConfig | `~/Library/Application Support/Google/AndroidStudio*` | yellow | Q | only versions older than installed |
| android.avd | `~/.android/avd/*.avd` | red | F | `avdmanager delete avd -n <name>` |
| android.systemImages | `~/Library/Android/sdk/system-images/*` | yellow | F | `sdkmanager --uninstall "system-images;..."` |

### Unity (`com.unity3d.unityhub`)
| id | path | tier | act | notes |
|---|---|---|---|---|
| unity.cache | `~/Library/Unity/cache` | yellow | Q | verify |
| unity.assetStore | `~/Library/Unity/Asset Store-5.x` | yellow | Q | redownload from Asset Store |
| unity.editors | `/Applications/Unity/Hub/Editor/*` | yellow | F | uninstall unused versions from Unity Hub |
| unity.logs | `~/Library/Logs/Unity` | green | Q | |
Project level `Library/ Temp/ Obj/ Logs/` handled by `project-graveyard.md`.

### Docker (`com.docker.docker`)
| id | path | tier | act | notes |
|---|---|---|---|---|
| docker.vmDisk | `~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw` | yellow | F | `docker system df` then `docker system prune -a` and `docker builder prune -a`. Never move |

### Ollama (`com.electron.ollama`, verify bundle id)
| id | path | tier | act | notes |
|---|---|---|---|---|
| ollama.models | `~/.ollama/models` | yellow | F | parse `manifests/registry.ollama.ai/library/<model>/<tag>` JSON, list each model with summed layer sizes, command `ollama rm <model>:<tag>` |

### VMware Fusion (`com.vmware.fusion`)
| id | path | tier | act | notes |
|---|---|---|---|---|
| vmware.vms | `~/Virtual Machines.localized/*.vmwarevm` | red | F | delete from VMware library. Show size and last modified per VM |

### Node, Python, Rust, Go, Swift, Ruby (no app, always active)
| id | path | tier | act | notes |
|---|---|---|---|---|
| npm.cache | `~/.npm/_cacache` | green | Q | |
| yarn.cache | `~/Library/Caches/Yarn` | green | Q | |
| pnpm.store | `~/Library/pnpm/store` | yellow | F | `pnpm store prune`, hard links make moving pointless |
| bun.cache | `~/.bun/install/cache` | green | Q | |
| pip.cache | `~/Library/Caches/pip` | green | Q | |
| uv.cache | `~/.cache/uv` | green | F | `uv cache clean` |
| conda.pkgs | `~/*conda3/pkgs` | yellow | F | `conda clean --all` |
| python38 | `/Library/Frameworks/Python.framework/Versions/3.8` | red | F | end of life interpreter, remove manually if unused |
| cargo.registry | `~/.cargo/registry/cache` | green | Q | |
| go.modcache | `~/go/pkg/mod` | yellow | F | `go clean -modcache` (files are read only) |
| spm.cache | `~/Library/Caches/org.swift.swiftpm` | green | Q | |
| cocoapods.cache | `~/Library/Caches/CocoaPods` | green | Q | |
| homebrew.cache | `~/Library/Caches/Homebrew` | green | Q | also suggest `brew cleanup --prune=all` |

### Creative apps
| id | path | tier | act | notes |
|---|---|---|---|---|
| adobe.mediaCache | `~/Library/Application Support/Adobe/Common/Media Cache Files` | green | Q | |
| adobe.mediaCacheDB | `~/Library/Application Support/Adobe/Common/Media Cache` | green | Q | |
| adobe.caches | `~/Library/Caches/Adobe` | green | Q | |
| resolve.cacheClip | `~/Movies/CacheClip` | green | Q | quit DaVinci Resolve, path is user configurable, verify |
| blender.oldConfig | `~/Library/Application Support/Blender/*` | yellow | Q | only version folders older than installed |

### Apps with Electron or WebKit caches (generic rule)
`appcache.generic`: for each installed app support folder `~/Library/Application Support/<name>`, the subfolders `Cache`, `Code Cache`, `GPUCache`, `DawnCache`, `Service Worker/CacheStorage`, `CachedData` are green Q, require app quit. Covers Discord, Slack style apps, Claude, ChatGPT, Notion, Figma, Postman, Obsidian, VS Code, Antigravity, Trello, Miro, WhatsApp desktop.
`appcache.library`: each `~/Library/Caches/<bundle id or name>` of an installed app is green Q when app is quit. Excludes `com.apple.*`.

### App scope rules (`appScope`)
The two rules above only see `<app name>/<subfolder>` one level deep. Real Electron and Chromium apps nest their caches (`Notion/Partitions/notion/...`, `Figma/DesktopProfile/v43/...`, `Google/Chrome/Profile 1/...`) and name their folder after something other than the app (`RealtimeBoard` is Miro, `Code` is VS Code). All rows are green, Q, claim the whole folder, require app quit, category appCache.
| id | root | matches | notes |
|---|---|---|---|
| appcache.chromium | `~/Library/Application Support` | `Code Cache`, `GPUCache`, `DawnCache`, `DawnWebGPUCache`, `DawnGraphiteCache`, `GraphiteDawnCache`, `ShaderCache`, `GrShaderCache`, `Service Worker/CacheStorage`, `Service Worker/ScriptCache`, `CachedData`, 1 to 4 levels below `<top>` | `com.apple.*` tops skipped |
| appcache.chromiumHTTP | `~/Library/Application Support` | `Cache` 1 to 4 levels below `<top>`, only when it contains `Cache_Data` | the marker keeps non Chromium folders called Cache out |
| appcache.libraryFallback | `~/Library/Caches` | every other top level folder | skips `com.apple.*` and its own list of Apple owned unprefixed folders (CloudKit, GeoServices, GameKit, icloudmailagent, FamilyCircle, PassKit, Metal, TemporaryItems, Apple daemons...). It does not reuse `system-allowlist.json`: shared vendor folders there (JetBrains, Code, Python, Google, Microsoft) are plain caches under `~/Library/Caches`. `Caches/Google` is still skipped because it is an ancestor of `chrome.cache` |
| appcache.container | `~/Library/Containers` | `<bundle id>/Data/Library/Caches` | skips `com.apple.*` |
| appcache.updater | `~/Library/Application Support/Caches` | `*-updater` folders (electron-updater downloads) | |

Never matched: `Local Storage`, `IndexedDB`, `WebStorage`, `Session Storage`, `File System`, `databases`, `Cookies`, `User`, `Service Worker/Database`, and every folder between `<top>` and the match.

**Attribution.** When a scan starts, `activeRules` lists each root once (plus the children of vendor folders) and writes one rule copy per child folder, so evaluation stays a dictionary lookup on `<top>` or `<top>/<second>` plus a suffix compare on shallow entries; the only extra syscall is the `Cache_Data` lstat for folders named `Cache`. A folder belongs to an installed app when, in order: its name is the app's bundle id; it starts with `<bundle id>.` (`com.microsoft.VSCode.ShipIt`); its normalized key (lowercase, letters and digits only) equals the key of the app name, bundle file name, bundle id, `CFBundleExecutable` or the last bundle id part (`realtimeboard`); for `<name>-updater` folders only, `<name>` does when it has at least 4 characters (`unityhub-updater`; `claude-cli-nodejs` is never Claude's). Vendor folders try `<top><second>` then `<second>` (`Google`+`Chrome`, `BraveSoftware`/`Brave-Browser`). Generic keys (`desktop`, `client`, `app`, `electron`...) and keys under 3 characters never attribute. Attributed copies take the app name as group and its bundle id, so quarantine is blocked while it runs. The rest go to group `Other App Caches` with the folder name as bundle id when it looks like one, take `unattributedReason`, and for `appcache.libraryFallback` the yellow tier (folders like `pypoetry` or `ms-playwright` can hold virtual environments or browser builds, so they are not preselected). Quarantine blocks an unattributed app cache with no bundle id when a running app's localized or executable name has the same normalized key as its `<top>` (or the `<name>` of `<name>-updater`); this is best effort and only checked at move time.

**Precedence.** App scope hits rank by the length of their root, so any path rule on the same folder wins (Homebrew, pip, Yarn, CocoaPods, spm, Xcode, Spotify, `appcache.generic`, `appcache.library`). A scope match that is an ancestor of a path rule (`~/Library/Caches/Google` above `chrome.cache`) is skipped like any other claim.

**Orphans.** An unattributed match whose `<top>` sits directly in a Library location the orphan detector scans (`Application Support`, `Caches`, `Containers`) is not emitted during the walk. It is held in `DeferredAppCaches` (the walk still descends, so sizes stay in the tree) and decided after the orphan pass has run: if the pass reported `<top>` (or anything overlapping the cache) the cache is dropped, so a deleted app's folder stays one whole orphan; otherwise the cache is sized and emitted then. The decision is the orphan pass's own result, not a prediction, so recency, protection, older versions and other rules' candidates inside `<top>` all count exactly as the pass saw them. Nested held caches keep only the outermost. Either way a folder is counted once. `CompiledRuleSet.claims` ignores app scope rules on purpose so the orphan pass can still see `<top>`.

### Specific app extras
| id | path | tier | act | notes |
|---|---|---|---|---|
| vscode.vsix | `~/Library/Application Support/Code/CachedExtensionVSIXs` | green | Q | same for Antigravity, verify folder name |
| vscode.oldExt | `~/.vscode/extensions/*` | yellow | Q | only older versions of an extension that has a newer one installed |
| chrome.cache | `~/Library/Caches/Google/Chrome` | green | Q | quit Chrome |
| spotify.cache | `~/Library/Caches/com.spotify.client` | green | Q | |
| spotify.offline | `~/Library/Application Support/Spotify/PersistentCache` | yellow | Q | offline songs redownload |
| steam.httpCache | `~/Library/Application Support/Steam/appcache/httpcache` | green | Q | |
| steam.games | `~/Library/Application Support/Steam/steamapps/common/*` | red | F | uninstall from Steam, show size and last played via `appmanifest_*.acf` LastPlayed |
| telegram.media | `~/Library/Group Containers/*.ru.keepcoder.Telegram` | yellow | F | Telegram > Settings > Data and Storage > Storage Usage, verify |
| mobileSync.backups | `~/Library/Application Support/MobileSync/Backup/*` | red | F | each backup with device name from `Info.plist`, delete via Finder or iMazing |
| arduino.staging | `~/Library/Arduino15/staging` | green | Q | |
| rpiImager.cache | `~/Library/Caches/Raspberry Pi/Imager` | green | Q | verify |
| mail.downloads | `~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads` | green | Q | |
| logs.user | `~/Library/Logs/*` | green | Q | entries older than 30 days only |
| crashReports | `~/Library/Logs/DiagnosticReports` | green | Q | |
| zoom.recordings | `~/Documents/Zoom/*` | red | Q | via old and large thresholds |

## Edge Cases
- Two rules match the same path: most specific path wins (longest literal prefix), ties go to higher tier severity (red over yellow over green)
- Glob `*` matches one segment only, `**` is not allowed in rules (performance)
- Rule path exists but is a symlink: skip, never resolve
- App running at evaluation time: candidate still listed, but quarantine is blocked later with `appRunning`
- Old version detection (`android.oldStudioConfig`, `blender.oldConfig`, `vscode.oldExt`): compare version strings with semantic compare, never mark the currently installed version
- JSON decode uses strict decoding, unknown keys throw. `appScope.owner` and `attributed` are runtime only and rejected in JSON
- App scope names compare case insensitively; a folder created after the scan started is not attributed until the next scan
- Rule candidates store their rule group (`candidate.rule_group`, migration v2), so App Caches lists group per app (`Notion`, `Miro`, `Other App Caches`) and the blocked hint names the app. Rows without a group (before v2, orphans, duplicates, projects) fall back to the catalog group of their rule id

## UI Requirements
- Dev Caches and App Caches screens group candidates by `group` with a collapsible header showing group total
- Inspector shows rule reason, tier glyph and label, matched rule id in secondary text
- Flagged screen: one row per flagOnly candidate, size, reason, command in monospaced text with Copy button. No run button in v1
- Settings > Profiles lists groups, detected apps and versions, toggle per group
