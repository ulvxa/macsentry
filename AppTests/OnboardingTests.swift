import Foundation
import MacSentryCore
import MacSentryTestSupport
import Testing
@testable import MacSentry

@MainActor
struct OnboardingTests {
    private func makeModel(granted: Bool, limitedMode: Bool = false) throws -> (AppModel, PermissionServiceDouble) {
        let fixture = try FixtureBuilder(name: "Onboarding")
        let store = try SettingsStore(defaults: fixture.isolatedDefaults(), homeURL: fixture.root)
        store.limitedMode = limitedMode
        let permissions = PermissionServiceDouble(granted: granted)
        let model = try AppModel(
            environment: fixture.environment(),
            settingsStore: store,
            permissions: permissions,
            notifier: SilentLowSpaceNotifier(),
        )
        return (model, permissions)
    }

    @Test func `decision table`() {
        #expect(OnboardingDecision.shouldPresent(hasFullDiskAccess: false, limitedMode: false))
        #expect(!OnboardingDecision.shouldPresent(hasFullDiskAccess: true, limitedMode: false))
        #expect(!OnboardingDecision.shouldPresent(hasFullDiskAccess: false, limitedMode: true))
        #expect(!OnboardingDecision.shouldPresent(hasFullDiskAccess: true, limitedMode: true))
    }

    @Test func `missing access and not limited shows sheet`() throws {
        let (model, _) = try makeModel(granted: false)
        #expect(model.isOnboardingPresented)
        #expect(!model.showsLimitedModeBadge)
    }

    @Test func `granted access hides sheet`() throws {
        let (model, _) = try makeModel(granted: true)
        #expect(!model.isOnboardingPresented)
        #expect(model.hasFullDiskAccess)
    }

    @Test func `limited mode hides sheet and shows badge`() throws {
        let (model, _) = try makeModel(granted: false, limitedMode: true)
        #expect(!model.isOnboardingPresented)
        #expect(model.showsLimitedModeBadge)
    }

    @Test func `continue with limited scan persists and hides`() throws {
        let (model, _) = try makeModel(granted: false)
        model.continueWithLimitedScan()
        #expect(!model.isOnboardingPresented)
        #expect(model.settings.store.limitedMode)
        #expect(model.showsLimitedModeBadge)
    }

    @Test func `granting then rechecking hides sheet and badge`() throws {
        let (model, permissions) = try makeModel(granted: false)
        permissions.granted = true
        model.refreshPermissions()
        #expect(!model.isOnboardingPresented)
        #expect(!model.showsLimitedModeBadge)
    }

    @Test func `open settings goes through permission service`() throws {
        let (model, permissions) = try makeModel(granted: false)
        model.permissions.openFullDiskAccessSettings()
        #expect(permissions.openCount == 1)
    }
}

extension FixtureBuilder {
    func isolatedDefaults() throws -> UserDefaults {
        // An absolute suite name keeps the plist inside the fixture instead of ~/Library/Preferences.
        try #require(UserDefaults(suiteName: url("prefs/settings").path(percentEncoded: false)))
    }

    func environment() throws -> AppEnvironment {
        try AppEnvironment(
            arguments: [
                "MacSentry",
                "-MacSentryScanRoot", root.path(percentEncoded: false),
                "-MacSentryDryRun", "YES",
                "-MacSentryDatabasePath", url("db/macsentry.sqlite").path(percentEncoded: false),
            ],
            realHomeURL: root,
        )
    }
}
