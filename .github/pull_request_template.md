## What and why

<!-- What does this change, and why? Link the issue: Closes #123 -->

## How it was tested

<!-- Tests added, fixture used, manual steps. Screenshots or a clip for UI changes. -->

## Safety checklist

- [ ] No `removeItem` anywhere. The only destructive call is still `FileManager.trashItem` inside `QuarantineService`
- [ ] Every new move path goes through `ProtectionPolicy.check` first
- [ ] Tests only touch temp dirs built by `FixtureBuilder`, never the real home folder
- [ ] I ran the app with the `MacSentry Dev` scheme (or `-MacSentryScanRoot <fixture>` and `-MacSentryDryRun YES`), not against my real disk
- [ ] No `sudo`, `rm` or cleanup CLIs (docker, brew, xcrun simctl, ollama) are run by the app, scripts or tests
- [ ] New rules: correct tier, never match user data, `flagOnly` + `cliCommand` where the owning tool must clean up, fixture test with a near miss
- [ ] No new network access and no new third party dependencies

## Done bar

- [ ] `xcodegen generate` and build succeed
- [ ] `swift test --package-path Packages/MacSentryCore` passes
- [ ] App tests pass (`xcodebuild ... test`)
- [ ] `swiftlint --strict` is clean and `swiftformat .` leaves no changes
- [ ] Relevant `docs/features/*.md` updated if behaviour changed
- [ ] `project.yml` does not include my personal `DEVELOPMENT_TEAM`
