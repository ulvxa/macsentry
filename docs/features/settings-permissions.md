# Settings and Permissions

## Full Disk Access
MacSentry is not sandboxed and needs Full Disk Access to read `~/Library/Containers`, `~/Library/Group Containers`, `MobileSync`, Mail and other TCC protected folders.

Detection (`PermissionService.hasFullDiskAccess()`): try to open `~/Library/Containers/com.apple.stocks` contents listing and `/Library/Application Support/com.apple.TCC/TCC.db` for reading. Either succeeding means granted. Never write anything during the check.

Onboarding sheet (shown on launch when missing, also from Settings):
1. One sentence on why: "MacSentry needs to see your whole disk to find what is taking space. It never deletes anything on its own."
2. Button "Open Privacy Settings": `NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)`
3. Instruction to drag the app or press + and pick MacSentry, then "Relaunch MacSentry" button (`NSApp.relaunch` via `open -n` of bundle path then terminate)
4. "Continue with limited scan" link, sets `limitedMode = true` and shows a toolbar badge

## Code Signing Note (personal build)
Full Disk Access is tied to the code signature. Ad hoc signing changes every build and macOS forgets the grant. Sign every build with the same Apple Development certificate (free Apple ID team works) by setting `DEVELOPMENT_TEAM` and `CODE_SIGN_STYLE: Automatic` in `project.yml`. Hardened runtime on, sandbox off.

## SettingsStore Keys (UserDefaults, `@AppStorage` in the app)
| key | type | default | UI |
|---|---|---|---|
| `thresholds.minAgeDays` | Int | 180 | Thresholds tab slider plus presets |
| `thresholds.minSizeBytes` | Int64 | 500_000_000 | Thresholds tab log slider |
| `thresholds.ageBasis` | String | `lastUsed` | Picker: Last opened, Last modified, Created |
| `scan.roots` | [String] | `["/"]` | General tab list editor |
| `projects.roots` | [String] | `["~"]` | Projects tab |
| `projects.idleDays` | Int | 90 | Projects tab |
| `duplicates.roots` | [String] | see `duplicate-finder.md` | Duplicates tab |
| `duplicates.minSizeBytes` | Int64 | 1_000_000 | Duplicates tab |
| `profiles.disabledGroups` | [String] | `[]` | Profiles tab toggles |
| `menuBar.enabled` | Bool | true | General |
| `menuBar.showText` | Bool | true | General |
| `launchAtLogin` | Bool | false | General (mirrors `SMAppService` status, source of truth is the service) |
| `diskAlert.enabled` | Bool | true | Notifications |
| `diskAlert.thresholdBytes` | Int64 | 30_000_000_000 | Notifications |
| `appearance` | String | `system` | Appearance |
| `limitedMode` | Bool | false | hidden |

Launch arguments override defaults for dev (`-MacSentryScanRoot`, `-MacSentryDryRun`, `-MacSentryDatabasePath`), read once by `AppEnvironment`.

## Settings Window Tabs
- **General**: scan roots, menu bar, launch at login, Full Disk Access status with button
- **Thresholds**: age, size, age basis, live preview text "Currently matches 214 items, 61.3 GB" from the last session
- **Profiles**: detected app groups with versions, toggle per group, rule count
- **Never Touch**: built in list (read only, collapsed), user patterns table with add, remove, note, test field ("Type a path to see if it is protected")
- **Projects** and **Duplicates**: their roots and thresholds
- **Notifications**: low space alert toggle and threshold
- **Appearance**: System, Light, Dark

## API

```swift
public protocol PermissionService: Sendable {
    func hasFullDiskAccess() -> Bool
    func openFullDiskAccessSettings()
}
public protocol NeverTouchStore: Sendable {
    func patterns() async throws -> [NeverTouchPattern]
    func add(_ pattern: String, note: String?) async throws
    func remove(id: Int64) async throws
}
```

## Edge Cases
- Invalid glob in Never Touch: reject with inline error, do not save
- Pattern that would protect everything (`/`, `~`, `**`): allowed but shows a warning that scans will find nothing
- Threshold change while a scan runs: applies to the filter instantly, rule evaluation uses the values captured at scan start
- `scan.roots` containing a path that does not exist: shown with a warning icon, skipped at scan time
