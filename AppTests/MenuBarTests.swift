import AppKit
import Foundation
import MacSentryCore
import MacSentryTestSupport
import Synchronization
import Testing
@testable import MacSentry

@MainActor
struct MenuBarTests {
    private static let gigabyte: Int64 = 1_000_000_000

    private func makeController(
        fixture: FixtureBuilder,
        notifier: any LowSpaceNotifier,
        sampler: FakeVolumeSampler,
        clock: TestClock = TestClock(),
        alertEnabled: Bool = true,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) },
    ) throws -> DiskPressureController {
        let store = try SettingsStore(defaults: fixture.isolatedDefaults(), homeURL: fixture.root)
        store.diskAlertEnabled = alertEnabled
        store.diskAlertThresholdBytes = 30 * Self.gigabyte
        return DiskPressureController(
            store: store,
            notifier: notifier,
            sampler: sampler,
            sleep: sleep,
            now: { clock.now },
        )
    }

    @Test func `terminate after last window follows the menu bar toggle`() {
        #expect(!AppDelegate.shouldTerminateAfterLastWindowClosed(menuBarEnabled: true))
        #expect(AppDelegate.shouldTerminateAfterLastWindowClosed(menuBarEnabled: false))
    }

    @Test func `delegate reads the live menu bar setting`() throws {
        let fixture = try FixtureBuilder(name: "MenuBarDelegate")
        let model = try AppModel(
            environment: fixture.environment(),
            settingsStore: SettingsStore(defaults: fixture.isolatedDefaults(), homeURL: fixture.root),
            notifier: SilentLowSpaceNotifier(),
        )
        let delegate = AppDelegate()
        delegate.connect(to: model)
        model.settings.menuBarEnabled = true
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(.shared))
        model.settings.menuBarEnabled = false
        #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(.shared))
    }

    @Test func `launch installs the notification delegate through the injected hook`() {
        let delegate = AppDelegate()
        var installed: NotificationResponder?
        delegate.installNotificationDelegate = { installed = $0 }
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        #expect(installed === delegate.notificationResponder)
    }

    @Test func `compact free space formatting`() {
        #expect(MenuBarFormatting.compactFree(212_400_000_000, locale: Locale(identifier: "en_US")) == "212 GB")
        #expect(MenuBarFormatting.compactFree(9_440_000_000, locale: Locale(identifier: "en_US")) == "9.4 GB")
        #expect(MenuBarFormatting.compactFree(10_000_000_000, locale: Locale(identifier: "en_US")) == "10 GB")
        #expect(MenuBarFormatting.compactFree(1_230_000_000_000, locale: Locale(identifier: "en_US")) == "1.2 TB")
        #expect(MenuBarFormatting.compactFree(640_000_000, locale: Locale(identifier: "en_US")) == "640 MB")
        #expect(MenuBarFormatting.compactFree(-5, locale: Locale(identifier: "en_US")) == "0 MB")
        let sample = DiskSample(sampledAt: Date(), totalBytes: 500, freeBytes: 100, importantFree: 215)
        #expect(MenuBarFormatting.percentFree(sample) == 43)
    }

    @Test func `a sample is stored on every interval tick`() async throws {
        let fixture = try FixtureBuilder(name: "MenuBarTicks")
        let clock = TestClock()
        let gate = TickGate()
        let intervals = Mutex<[Duration]>([])
        let sampler = FakeVolumeSampler(total: 500 * Self.gigabyte, free: 100 * Self.gigabyte)
        let controller = try makeController(fixture: fixture, notifier: RecordingNotifier(), sampler: sampler, clock: clock) { duration in
            intervals.withLock { $0.append(duration) }
            try await gate.wait()
        }
        try await controller.attach(database: Database.inMemory())

        for tick in 1 ... 4 {
            clock.advance(15 * 60)
            sampler.set(VolumeCapacity(
                total: 500 * Self.gigabyte,
                available: 100 * Self.gigabyte,
                importantAvailable: Int64(100 + tick) * Self.gigabyte,
            ))
            await gate.tick()
            let expected = Int64(100 + tick) * Self.gigabyte
            #expect(await eventually { controller.latest?.importantFree == expected })
        }
        await controller.refresh()

        let stored = controller.sparkline?.points.reduce(0) { $0 + $1.sampleCount }
        #expect(stored == 5)
        #expect(intervals.withLock { $0 }.allSatisfy { $0 == .seconds(15 * 60) })
        #expect(!intervals.withLock { $0 }.isEmpty)
    }

    @Test func `notification fires once per crossing and re arms after recovery`() async throws {
        let fixture = try FixtureBuilder(name: "MenuBarCrossing")
        let notifier = RecordingNotifier()
        let sampler = FakeVolumeSampler(total: 500 * Self.gigabyte, free: 50 * Self.gigabyte)
        let controller = try makeController(fixture: fixture, notifier: notifier, sampler: sampler)
        try await controller.attach(database: Database.inMemory())

        for free in [25, 20, 28, 33, 40, 22, 10] {
            sampler.set(VolumeCapacity(
                total: 500 * Self.gigabyte,
                available: Int64(free) * Self.gigabyte,
                importantAvailable: Int64(free) * Self.gigabyte,
            ))
            await controller.sampleNow()
        }

        #expect(await eventually { controller.latest?.importantFree == 10 * Self.gigabyte })
        #expect(notifier.posts == [25 * Self.gigabyte, 22 * Self.gigabyte])
        #expect(controller.isLow)
    }

    @Test func `no notification while alerts are disabled`() async throws {
        let fixture = try FixtureBuilder(name: "MenuBarAlertsOff")
        let notifier = RecordingNotifier()
        let sampler = FakeVolumeSampler(total: 500 * Self.gigabyte, free: 50 * Self.gigabyte)
        let controller = try makeController(fixture: fixture, notifier: notifier, sampler: sampler, alertEnabled: false)
        try await controller.attach(database: Database.inMemory())

        sampler.set(VolumeCapacity(total: 500 * Self.gigabyte, available: 10 * Self.gigabyte, importantAvailable: 10 * Self.gigabyte))
        await controller.sampleNow()

        #expect(await eventually { controller.latest?.importantFree == 10 * Self.gigabyte })
        #expect(notifier.posts.isEmpty)
        #expect(controller.isLow)
    }

    @Test func `permission is requested on first enable only and never again once denied`() async throws {
        let fixture = try FixtureBuilder(name: "MenuBarPermission")
        let notifier = RecordingNotifier(status: .notDetermined, statusAfterRequest: .denied)
        let controller = try makeController(
            fixture: fixture,
            notifier: notifier,
            sampler: FakeVolumeSampler(total: 500 * Self.gigabyte, free: 100 * Self.gigabyte),
            alertEnabled: false,
        )
        #expect(notifier.requests == 0)

        await controller.setAlertEnabled(true)
        #expect(notifier.requests == 1)
        #expect(controller.authorization == .denied)

        await controller.setAlertEnabled(false)
        await controller.setAlertEnabled(true)
        #expect(notifier.requests == 1)
        #expect(controller.authorization == .denied)
    }

    @Test func `launch at login toggles through the service and mirrors its status`() throws {
        let fixture = try FixtureBuilder(name: "MenuBarLogin")
        let store = try SettingsStore(defaults: fixture.isolatedDefaults(), homeURL: fixture.root)
        let service = FakeLoginItemService()
        let controller = LoginItemController(service: service) { store.launchAtLogin = $0 }
        #expect(!controller.isOn)

        controller.setEnabled(true)
        #expect(service.registerCalls == 1)
        #expect(controller.isOn)
        #expect(store.launchAtLogin)

        controller.setEnabled(false)
        #expect(service.unregisterCalls == 1)
        #expect(!controller.isOn)
        #expect(!store.launchAtLogin)
    }

    @Test func `launch at login surfaces approval and failures`() {
        let service = FakeLoginItemService()
        service.registerResult = .requiresApproval
        let controller = LoginItemController(service: service)
        controller.setEnabled(true)
        #expect(controller.isOn)
        #expect(controller.needsApproval)

        service.status = .notRegistered
        service.failure = CocoaError(.fileWriteNoPermission)
        controller.setEnabled(true)
        #expect(!controller.isOn)
        #expect(controller.errorMessage != nil)

        service.status = .enabled
        controller.refresh()
        #expect(controller.isOn)
    }
}
