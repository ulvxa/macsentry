# Orphan Detector

Finds leftovers in `~/Library` from apps that are no longer installed, plus support folders for old versions of apps that are installed.

## Locations Checked (top level children only)
| location | identity source | default tier | action |
|---|---|---|---|
| `~/Library/Application Support/*` | folder name (bundle id or app name) | yellow | Q |
| `~/Library/Caches/*` | folder name | green | Q |
| `~/Library/Containers/*` | `.com.apple.containermanagerd.metadata.plist` key `MCMMetadataIdentifier` | yellow | Q |
| `~/Library/Group Containers/*` | name after the team id prefix | yellow | Q |
| `~/Library/Saved Application State/*.savedState` | bundle id in name | green | Q |
| `~/Library/HTTPStorages/*` | bundle id | green | Q |
| `~/Library/WebKit/*` | bundle id | green | Q |
| `~/Library/Logs/*` | folder name | green | Q |
| `~/Library/Preferences/*.plist` | bundle id in name | green | Q, size threshold 0 but grouped |
| `~/Library/LaunchAgents/*.plist` | `Label` key | red | F, command `launchctl bootout gui/$(id -u) <path>` then remove |

## Matching
1. Build `knownIDs` = installed bundle ids + every `CFBundleIdentifier` found inside installed app bundles (helpers, login items under `Contents/Library/LoginItems`, `Contents/Helpers`)
2. Build `knownNames` = installed app names, lowercased, spaces and punctuation stripped
3. A folder is NOT an orphan if any of:
   - name equals or has prefix of a `knownID` (`com.spotify.client.helper` → `com.spotify.client`)
   - normalized name equals or contains a `knownName` of length 4 or more
   - name starts with `com.apple.` or is in `SystemAllowlist` (`CloudDocs`, `CallHistoryDB`, `AddressBook`, `Knowledge`, `CrashReporter`, `SyncServices`, `icdd`, `FileProvider`, `iCloud`, `Dock`, `com.crashlytics`, `Google` (if any Google app installed), `Microsoft`, `Adobe` (if any Adobe app installed), `JetBrains`, `Code` (VS Code), `Python`, `Homebrew`, etc. Stored as `Resources/Rules/system-allowlist.json`)
   - it is claimed by another rule, or contains a candidate a rule already emitted. Unattributed app scope caches (`rules-engine.md`) are held back until this pass finishes and only emitted for folders it did not report, so a deleted app's leftover stays one whole orphan
   - a token of the identity (reverse DNS parts after the TLD, minus generic words) names an installed command line tool or SDK: `CLIToolInventory`, built once per scan from directory listings only (Homebrew Cellar/Caskroom, bin dirs, npm/bun globals, Toolbox, Android SDK; roots are injected). Alias `qtproject` → `qt`
   - LaunchServices knows an app for it: `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` returns non nil
4. Otherwise orphan. Confidence:
   - `high`: name is reverse DNS and no known id shares its first two components
   - `medium`: reverse DNS but shares vendor prefix with an installed app (`com.microsoft.teams` with Office installed)
   - never `high` for SDK/installer vendors (`firebase`, `install4j`, `qtproject`, `sentry`, `crashlytics`, ...): they are written by other tools, so these are `low`
   - `low`: plain name with no match (could be a CLI tool's data)

## Old Version Folders
Folders like `AndroidStudio2023.1`, `Blender/3.6`, `JetBrains/IntelliJIdea2022.3` where a newer version of the same product is installed are orphans with `medium` confidence and `reason = "Settings from an older version"`.

## API

```swift
public protocol OrphanDetector: Sendable {
    func detect(inventory: [InstalledApp], library: URL) async throws -> [Candidate]
}
```

## Edge Cases
- Apps installed outside standard folders (Steam games, Unity editors, apps in `~/Downloads`): include `~/Applications`, `/Applications/Unity/Hub/Editor/*/Unity.app`, and any app LaunchServices resolves
- CLI tools with Library data and no app (`ollama`, `docker` CLI only, `gh`): `low` confidence, never preselected
- Container folders with unreadable metadata: `low`
- Orphans never default to selected, regardless of tier
- LaunchAgents of running processes: flagOnly, reason includes the program path from the plist

## UI Requirements
- Orphans screen grouped by confidence (High, Medium, Low sections), each row shows guessed app name, location type, size, last modified
- Inspector shows why it is considered orphaned (which checks failed) and a "This app is still installed" button that adds the name to the never touch list
