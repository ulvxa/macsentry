# Contributing to MacSentry

Thanks for helping. MacSentry moves files on real people's disks, so the bar is simple: correct, tested, and safe. This guide covers everything you need.

## Setup

Requirements: macOS 26, Apple Silicon, Xcode 26 (opened once, `xcode-select -p` pointing at Xcode.app), Homebrew.

```bash
brew install xcodegen swiftlint swiftformat
git clone https://github.com/ulvxa/macsentry.git
cd macsentry
xcodegen generate
open MacSentry.xcodeproj
```

- The Xcode project is generated from `project.yml`. Never edit `MacSentry.xcodeproj` by hand, and do not commit it (it is gitignored). Change `project.yml` and rerun `xcodegen generate`.
- A fresh clone builds ad hoc signed. To keep Full Disk Access across rebuilds, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set your own `DEVELOPMENT_TEAM` (a free Apple ID team works). It is gitignored. Full Disk Access is tied to the code signature, so keep signing with the same certificate or macOS forgets the grant.
- The only third party dependency is [GRDB.swift](https://github.com/groue/GRDB.swift). Do not add others.

## Schemes: run against a fixture, not your home

| Scheme | What it does |
|---|---|
| **MacSentry Dev** | Builds a fake home at `/tmp/macsentry-dev/root` with `scripts/dev-fixture.sh`, scans only that, and runs in **dry run** (nothing moves on disk). Use this for day to day work. |
| **MacSentry** | Real scan of your disk, no dry run. Only use it when you mean to. |

To launch a built app by hand against your own fixture:

```bash
open MacSentry.app --args -MacSentryScanRoot /tmp/my-fixture -MacSentryDryRun YES -MacSentryDatabasePath /tmp/my-fixture.sqlite
```

When `-MacSentryScanRoot` is set, `~` in rules, protection patterns and project roots resolves to that root, so a fixture can mirror a real home layout.

## The done bar

A change is done when all of these pass:

```bash
xcodegen generate
xcodebuild -project MacSentry.xcodeproj -scheme MacSentry -destination 'platform=macOS' -quiet build
swift test --package-path Packages/MacSentryCore
xcodebuild -project MacSentry.xcodeproj -scheme MacSentry -destination 'platform=macOS' test
swiftlint --strict
swiftformat .
```

CI runs SwiftLint and the Core tests on every PR. Run the full list locally before asking for review.

Two Core tests are opt in: `MACSENTRY_PERF=1` runs the 200k file scan benchmark, and `MACSENTRY_REAL_TRASH=1` exercises the real `trashItem`.

## Safety rules (non negotiable)

PRs that break any of these will not be merged:

- Never call `removeItem` anywhere. The only destructive call allowed is `FileManager.trashItem` inside `QuarantineService`. SwiftLint enforces this with a custom rule.
- Every move goes through `ProtectionPolicy.check` first.
- Tests only touch temp dirs built by `FixtureBuilder`. Never read or write the real home folder in tests.
- When running the app during development, use the `MacSentry Dev` scheme or launch with `-MacSentryScanRoot <fixture dir>` and `-MacSentryDryRun YES`.
- Never run `sudo`, `rm`, or any cleanup CLI (docker, brew, xcrun simctl, ollama) as part of the app, scripts or tests. Risky stores are `flagOnly` with a `cliCommand` the user copies and runs themselves.
- Code never calls `FileManager.homeDirectoryForCurrentUser` directly; use `AppEnvironment.homeURL` so fixtures work.

## Code style

- `App/` is SwiftUI only. All logic lives in `Packages/MacSentryCore`, which has zero SwiftUI imports.
- Services are protocols in Core with one concrete implementation plus a test double.
- `async`/`await` and `AsyncThrowingStream` for long work. No Combine, no GCD unless wrapping C APIs.
- No force unwraps outside tests. Errors are typed enums conforming to `LocalizedError`.
- File URLs (`URL`) only, never raw `String` paths across module boundaries.
- Name clashes: write `MacSentryCore.Category` in App (SwiftUI has `Category`) and `GRDB.Database` in Core (ours is `Database`).
- Never give a wide-range `Slider` a `step` (macOS 26 draws a tick per step and freezes); use `DraftSlider`.
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`).
- UI is black and white with native Liquid Glass APIs only. See `docs/features/ui-shell.md`.
- Read the relevant spec in `docs/features/` before touching a domain, and update it when behaviour changes.

## Adding a cleanup rule

Rules are data. Most new detections need no Swift changes.

1. Read `docs/features/rules-engine.md` for the full field reference, precedence and edge cases.
2. Add an entry to the right file in `Packages/MacSentryCore/Sources/MacSentryCore/Resources/Rules/` (or `catalog-gaps.json` if nothing fits):

   ```json
   {
     "id": "npm.cache",
     "group": "Node",
     "category": "devCache",
     "tier": "green",
     "action": "quarantine",
     "match": { "paths": ["~/.npm/_cacache"], "claimWholeFolder": true },
     "appBundleIDs": [],
     "requiresAppQuit": false,
     "reason": "npm download cache. npm fetches packages again when needed.",
     "verify": false
   }
   ```

   - **Tier:** green regenerates by itself, yellow costs time or bandwidth to rebuild, red is user data.
   - **Action:** `quarantine`, or `flagOnly` with a `cliCommand` when the owning tool must do the removal.
   - Prefer specific literal paths. `*` matches one path segment; `**` is not allowed.
   - Never match user data: `Local Storage`, `IndexedDB`, `WebStorage`, `Session Storage`, `Cookies`, `File System`, `databases`, profile roots.
   - Set `verify: true` if you have not confirmed the path on a real Mac.
   - Decoding is strict: unknown keys fail the catalog test.
3. Add a fixture test under `Packages/MacSentryCore/Tests/MacSentryCoreTests/Rules/` asserting the hit, its rule id, tier, group and action, plus a near miss that must not match. `RuleCatalogGapTests.swift` shows the pattern with `FixtureBuilder` and `RuleTestKit`.
4. Add the rule to the catalog table in `docs/features/rules-engine.md`.
5. Run `swift test --package-path Packages/MacSentryCore --filter Rule`, then the full suite and `swiftlint --strict`.

Not comfortable writing the rule? Open a **New cleanup rule** issue with the path and what the app does with it.

## Pull requests

1. Open an issue first for anything larger than a bug fix or a rule, so the approach can be agreed before you build it.
2. Fork, branch from `main`, keep the change focused. One concern per PR.
3. Pass the done bar locally.
4. Fill in the PR template, including the safety checklist.
5. Screenshots or a short clip for any visible UI change.

## AI-assisted contributions

Welcome. The repo ships with a `CLAUDE.md` in `.claude/` describing the stack, commands and safety rules, plus project agents in `.claude/agents/` (`scout`, `core-dev`, `app-dev`, `rules-author`, `perf-probe`, `swift-reviewer`, `verifier`). `.claude/settings.json` denies `rm`, `sudo` and the cleanup CLIs for the agent. Keep those protections on.

You are responsible for every line you submit, whoever or whatever wrote it. Review the diff yourself and make sure it passes the done bar.

## Code of Conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). Be kind.
