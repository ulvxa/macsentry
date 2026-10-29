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
- JSON decode uses strict decoding, unknown keys throw

## UI Requirements
- Dev Caches and App Caches screens group candidates by `group` with a collapsible header showing group total
- Inspector shows rule reason, tier glyph and label, matched rule id in secondary text
- Flagged screen: one row per flagOnly candidate, size, reason, command in monospaced text with Copy button. No run button in v1
- Settings > Profiles lists groups, detected apps and versions, toggle per group
