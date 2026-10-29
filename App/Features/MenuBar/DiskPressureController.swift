import Foundation
import MacSentryCore
import Observation

@Observable
@MainActor
final class DiskPressureController {
    @ObservationIgnored let store: SettingsStore
    @ObservationIgnored private let notifier: any LowSpaceNotifier
    @ObservationIgnored private let sampler: any VolumeSampler
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var monitor: DiskMonitor?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var settingsTask: Task<Void, Never>?

    private(set) var latest: DiskSample?
    private(set) var sparkline: Sparkline?
    private(set) var readFailed = false
    private(set) var authorization: NotificationAuthorization = .notDetermined

    var alertEnabled: Bool {
        didSet {
            store.diskAlertEnabled = alertEnabled
            pushSettings()
        }
    }

    var alertThresholdBytes: Int64 {
        didSet {
            store.diskAlertThresholdBytes = alertThresholdBytes
            pushSettings()
        }
    }

    init(
        store: SettingsStore,
        notifier: any LowSpaceNotifier,
        sampler: any VolumeSampler = SystemVolumeSampler(),
        interval: Duration = DiskMonitor.defaultInterval,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() },
    ) {
        self.store = store
        self.notifier = notifier
        self.sampler = sampler
        self.interval = interval
        self.sleep = sleep
        self.now = now
        alertEnabled = store.diskAlertEnabled
        alertThresholdBytes = store.diskAlertThresholdBytes
    }

    isolated deinit {
        eventTask?.cancel()
        settingsTask?.cancel()
    }

    var isLow: Bool {
        guard let latest else { return false }
        return latest.importantFree < alertThresholdBytes
    }

    var isAttached: Bool {
        monitor != nil
    }

    func attach(database: Database) async {
        guard monitor == nil else { return }
        let monitor = DiskMonitor(
            sampler: sampler,
            database: database,
            settings: ThresholdSettings(isEnabled: alertEnabled, thresholdBytes: alertThresholdBytes),
            sleep: sleep,
            now: now,
        )
        self.monitor = monitor
        _ = try? await monitor.pruneSamples()
        let events = monitor.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await handle(event)
            }
        }
        await monitor.start(interval: interval)
        await refresh()
        authorization = await notifier.authorization()
    }

    func refresh() async {
        guard let monitor else { return }
        do {
            latest = try await monitor.currentSample()
            readFailed = false
        } catch {
            readFailed = latest == nil
        }
        sparkline = try? await monitor.sparkline()
    }

    func sampleNow() async {
        _ = try? await monitor?.sampleNow()
    }

    func handleWake() async {
        await monitor?.handleWake()
    }

    func setAlertEnabled(_ enabled: Bool) async {
        alertEnabled = enabled
        guard enabled else { return }
        await refreshAuthorization()
        if authorization == .notDetermined {
            await requestNotificationPermission()
        }
    }

    func refreshAuthorization() async {
        authorization = await notifier.authorization()
    }

    func requestNotificationPermission() async {
        authorization = await notifier.requestAuthorization()
    }

    func openNotificationSettings() async {
        await notifier.openSystemSettings()
    }

    private func handle(_ event: DiskEvent) async {
        switch event {
        case let .sample(sample):
            latest = sample
            readFailed = false
            sparkline = try? await monitor?.sparkline()
        case let .crossedBelowThreshold(sample):
            latest = sample
            if alertEnabled {
                await notifier.postLowSpace(freeBytes: sample.importantFree, thresholdBytes: alertThresholdBytes)
            }
        case let .recovered(sample):
            latest = sample
        }
    }

    private func pushSettings() {
        guard let monitor else { return }
        let settings = ThresholdSettings(isEnabled: alertEnabled, thresholdBytes: alertThresholdBytes)
        let previous = settingsTask
        settingsTask = Task {
            await previous?.value
            await monitor.updateSettings(settings)
        }
    }
}
