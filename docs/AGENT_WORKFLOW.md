# Agent Workflow (Claude Code)

> The maintainer's original build log: how MacSentry was built phase by phase with Claude Code. Kept for reference; contributors should start with [CONTRIBUTING.md](../CONTRIBUTING.md).

One phase per session. Plan first, build second, verify third, commit, `/clear`. Specs come in through `@` imports so the context only holds what the phase needs.

## 0. One Time Setup

```bash
# prerequisites: Xcode 26 installed and opened once, Apple ID added in Xcode > Settings > Accounts
xcode-select -p                      # must point to Xcode.app, not CommandLineTools
brew install xcodegen swiftlint swiftformat

mkdir -p ~/Developer/MacSentry && cd ~/Developer/MacSentry
git init
# copy the spec pack in (CLAUDE.md, docs/, .claude/)
cp -R ~/Downloads/macsentry-spec/. .
git add -A && git commit -m "chore: spec pack"

claude
```

`.claude/settings.json` in this pack blocks `rm`, `sudo`, and the cleanup CLIs for the agent. Keep it committed.

## 1. Per Phase Loop

```
Shift+Tab  (switch to plan mode)
<paste Phase Prompt>
review the plan, push back, approve
Shift+Tab  (back to normal / auto accept edits)
let it build
<paste Verify Prompt>
git commit (agent or you)
/clear
```

### Phase Prompt (template)

```
@CLAUDE.md @docs/PHASES.md @docs/features/<doc1>.md @docs/features/<doc2>.md

Implement Phase <N>: <name> from docs/PHASES.md. Nothing from later phases.
1. Give me a plan first: files you will create or change, types and their responsibilities, test list mapped to each acceptance criterion.
2. After I approve, implement in small steps. Run core tests after each step.
3. Finish by running build, core tests and lint from CLAUDE.md and paste the summary.
If a spec is ambiguous, pick the safer option and list your assumptions at the end. Do not edit docs/ unless I ask.
```

### Phase to Docs Map
| phase | imports after `@CLAUDE.md @docs/PHASES.md` |
|---|---|
| 0 Skeleton | `@docs/features/database-schema.md @docs/features/ui-shell.md` |
| 1 Permissions and Protection | `@docs/features/settings-permissions.md @docs/features/quarantine.md` |
| 2 Scan Engine | `@docs/features/scanner.md @docs/features/database-schema.md` |
| 3 Rules | `@docs/features/rules-engine.md @docs/features/scanner.md` |
| 4 Main UI | `@docs/features/ui-shell.md @docs/features/database-schema.md` |
| 5 Quarantine | `@docs/features/quarantine.md @docs/features/database-schema.md` |
| 6 Graveyard | `@docs/features/project-graveyard.md @docs/features/scanner.md` |
| 7 Orphans and Duplicates | `@docs/features/orphan-detector.md @docs/features/duplicate-finder.md` |
| 8 Menu Bar | `@docs/features/menu-bar.md @docs/features/settings-permissions.md` |
| 9 Hardening | `@docs/features/rules-engine.md @docs/features/quarantine.md` |

### Verify Prompt

```
Go through every acceptance criterion of Phase <N> in @docs/PHASES.md one by one.
For each: name the test or manual step that proves it, run it, mark PASS or FAIL.
For anything UI only, tell me exactly what to click and what I should see, I will check it.
Then grep the repo for `removeItem` and `rm -` and confirm zero hits outside tests.
```

### Commit Prompt

```
Commit everything for Phase <N> with message "phase <N>: <name>". Short body listing the main types added.
```

## 2. Manual App Runs During Development

Always against a fixture first, in dry run:

```bash
# build a disposable playground
mkdir -p /tmp/ms-playground && cd /tmp/ms-playground
mkdir -p Library/Developer/Xcode/DerivedData/Foo && mkfile 300m Library/Developer/Xcode/DerivedData/Foo/blob
mkdir -p code/oldapp/node_modules/x && echo '{}' > code/oldapp/package.json && mkfile 200m code/oldapp/node_modules/x/big
cd code/oldapp && git init -q && git commit -q --allow-empty -m init && cd -

# or just run the "MacSentry Dev" Xcode scheme: it builds /tmp/macsentry-dev/root via scripts/dev-fixture.sh and passes the flags below.
# The "MacSentry" scheme is a real scan without dry run.
# run the built app pointed at it
APP=$(find ~/Library/Developer/Xcode/DerivedData -path "*Build/Products/Debug/MacSentry.app" -maxdepth 6 | head -1)
open "$APP" --args -MacSentryScanRoot /tmp/ms-playground -MacSentryDryRun YES -MacSentryDatabasePath /tmp/ms.sqlite
```

The playground mirrors home relative paths, so rules with `~` must resolve `~` to the scan root when `MacSentryScanRoot` is set. Tell the agent this in Phase 2 if it misses it.

## 3. Bug Fix Prompt

```
@CLAUDE.md @docs/features/<relevant>.md

Bug: <what happened> 
Expected: <what should happen>
Repro: <steps or fixture>
First write a failing test that reproduces it, show me it fails, then fix, then run all core tests.
```

## 4. Adding a Rule Later

```
@CLAUDE.md @docs/features/rules-engine.md

Add a rule for <app>: path <path>, tier <tier>, action <quarantine|flagOnly>, reason "<text>".
Add it to the right JSON file and to the catalog table in rules-engine.md, add a fixture test, run core tests.
```

## 5. Real Machine Dry Run (Phase 9)

```
@CLAUDE.md @docs/features/rules-engine.md

I ran a real dry run scan. Here is the exported list of candidates with tier and rule id: <paste or attach>.
1. Flag anything that looks like user data marked green or yellow.
2. For every rule with verify: true, tell me which ones matched nothing so we can confirm or delete them.
3. Propose rule edits as a diff, do not apply until I say go.
```

## 6. Context Hygiene
- `/clear` between phases, always. The specs and git history carry state, not the chat
- If a phase drags past one session, ask the agent to write `docs/progress/phase-<N>.md` (done, remaining, gotchas), commit, `/clear`, and restart with that file imported
- Keep `CLAUDE.md` under 40 lines. Domain facts belong in `docs/features/`
- If the agent drifts into a later phase, stop it and paste: "Out of scope for Phase <N>, revert those files"
