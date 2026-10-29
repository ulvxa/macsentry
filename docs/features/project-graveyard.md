# Project Graveyard

Finds code projects you have not touched in a while and the regenerable build artifacts they are holding. Only artifact folders become candidates. Source code is never a candidate.

## Discovery
- Search roots: user home (default), configurable in Settings > Projects. Skips `~/Library`, the quarantine folder, and Trash
- A project root is a folder containing `.git` (dir or file, submodules use a file). Folders without git but with a manifest (`package.json`, `Cargo.toml`, `pyproject.toml`, `ProjectSettings/ProjectVersion.txt`, `settings.gradle*`, `Package.swift`) are also projects, marked `noGit`
- Nested projects (submodules, monorepo packages) are attached to the outermost git root for staleness, but artifacts are detected per package folder

## Artifact Catalog
| ecosystem | folder | required marker next to it | tier |
|---|---|---|---|
| node | `node_modules` | `package.json` | green |
| node | `.next`, `.nuxt`, `.turbo`, `.parcel-cache`, `.svelte-kit`, `.angular/cache` | `package.json` | green |
| python | `.venv`, `venv`, `env` | contains `pyvenv.cfg` | yellow |
| python | `__pycache__`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache`, `.tox` | none | green |
| rust | `target` | `Cargo.toml` | green |
| gradle | `build`, `.gradle` | `build.gradle*` or `settings.gradle*` | green |
| unity | `Library`, `Temp`, `Obj`, `Logs` | `ProjectSettings/ProjectVersion.txt` in same root | yellow (reimport takes long) |
| apple | `DerivedData`, `.build` | `*.xcodeproj` or `Package.swift` | green |
| apple | `Pods` | `Podfile` | yellow |
| flutter | `.dart_tool`, `build` | `pubspec.yaml` | green |
| generic | `dist`, `out` | `package.json` | yellow (could be committed output) |
| arduino | `build` | `*.ino` | green |

Once a folder matches, the walker gets `skipChildren` so `node_modules/*/node_modules` is never counted twice.

## Staleness
- `last_commit_at`: newest of the reflog timestamp (last line of `.git/logs/HEAD`, field 5) and `git log -1 --format=%ct` via `Process` with a 3 s timeout. If git is missing, reflog only
- `last_modified_at`: newest `modified` of non artifact files found during the walk
- Project age = now minus max(last_commit_at, last_modified_at)
- Uncommitted changes: `git status --porcelain --untracked-files=no` non empty, 3 s timeout, unknown on timeout

## Data Models
`project` and `candidate` tables (see `database-schema.md`). Artifacts are `candidate` rows with `category = projectArtifact`, `project_id` set, `rule_id = graveyard.<ecosystem>.<folder>`.

## API

```swift
public protocol ProjectScanner: Sendable {
    func isProjectRoot(_ dir: URL, entries: [String]) -> ProjectMarker?
    func artifact(for dir: URL, name: String, siblings: [String]) -> ArtifactMatch?
    func enrich(_ projects: [Project]) async -> [Project]   // git calls, run after walk, concurrency 4
}
```

## Edge Cases
- Project currently open: if Xcode, VS Code, Android Studio or Unity is running AND its recent documents include the project path, mark artifacts `appRunning` blocked. Simple version for v1: block if the related IDE is running and the project was modified in the last 24 h
- Symlinked `node_modules` (pnpm workspaces): never follow, size the link only
- `node_modules` inside `~/.npm` or global install dirs (`/opt/homebrew/lib/node_modules`) are NOT artifacts, protection policy plus root exclusion handles it
- `build` folder without a marker: ignored (could be anything)
- Repo on an active branch with uncommitted work: still listed, badge shown, never preselected
- Git timeout or corrupt repo: fall back to file dates, show "git unavailable" in inspector

## UI Requirements
- Projects screen: Table of projects sorted by artifacts size, columns Name, Path, Ecosystems (small text badges), Last activity (relative), Uncommitted badge, Artifacts size
- Age filter slider shared with global thresholds but can be overridden on this screen ("Idle for at least X days", default 90)
- Expanding a project shows its artifact rows with checkboxes, default checked for green only
- Action bar: "Quarantine artifacts of N projects, X GB"
- Inspector for a project: open in Finder, open in Terminal (`open -a Terminal <path>`), list of artifacts and why each is safe to regenerate (`npm install`, `pip install -r`, Unity reimport, etc)
