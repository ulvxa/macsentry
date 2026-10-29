import Foundation
import GRDB

public actor DiskMonitor {
    public static let retention: Duration = .seconds(90 * 86400)
    public static let defaultInterval: Duration = .seconds(15 * 60)

    private let sampler: any VolumeSampler
    private let database: Database
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date
    private let broadcaster = DiskEventBroadcaster()

    private var settings: ThresholdSettings
    // Armed/below state lives in memory only: after relaunch the first sample re-evaluates from scratch.
    private var tracker = ThresholdTracker()
    private var loop: Task<Void, Never>?

    public init(
        sampler: any VolumeSampler,
        database: Database,
        settings: ThresholdSettings = ThresholdSettings(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() },
    ) {
        self.sampler = sampler
        self.database = database
        self.settings = settings
        self.sleep = sleep
        self.now = now
    }

    deinit {
        loop?.cancel()
        broadcaster.finish()
    }

    // Each access returns an independent stream that receives events emitted after it was created.
    // swiftlint:disable:next modifier_order
    public nonisolated var events: AsyncStream<DiskEvent> {
        broadcaster.stream()
    }

    /// Takes one sample immediately, then one per `interval`. Calling again restarts the loop.
    public func start(interval: Duration) async {
        loop?.cancel()
        loop = nil
        _ = try? await sampleNow()
        let sleep = sleep
        loop = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep(interval) } catch { return }
                guard !Task.isCancelled, let monitor = self else { return }
                _ = try? await monitor.sampleNow()
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    public func updateSettings(_ newSettings: ThresholdSettings) {
        settings = newSettings
        if !newSettings.isEnabled {
            tracker.reset()
        }
    }

    /// Reads the volume now without storing or emitting anything.
    public func currentSample() throws -> DiskSample {
        try readSample()
    }

    /// Reads, stores and publishes a sample. Also the entry point for wake-from-sleep.
    @discardableResult
    public func sampleNow() async throws -> DiskSample {
        let sample = try readSample()
        do {
            try await database.writer.write { db in
                try sample.insert(db, onConflict: .replace)
            }
        } catch {
            throw DiskMonitorError.databaseFailed(reason: error.localizedDescription)
        }
        broadcaster.yield(.sample(sample))
        evaluateThreshold(for: sample)
        return sample
    }

    public func handleWake() async {
        _ = try? await sampleNow()
    }

    public func history(days: Int) async throws -> [DiskSample] {
        let cutoff = now().addingTimeInterval(-TimeInterval(days) * 86400).timeIntervalSince1970
        do {
            return try await database.writer.read { db in
                try DiskSample
                    .filter(Column("sampled_at") >= cutoff)
                    .order(Column("sampled_at"))
                    .fetchAll(db)
            }
        } catch {
            throw DiskMonitorError.databaseFailed(reason: error.localizedDescription)
        }
    }

    public func sparkline(days: Int = 30, bucket: Duration = Sparkline.defaultBucket) async throws -> Sparkline {
        try await Sparkline.make(samples: history(days: days), bucket: bucket)
    }

    /// Deletes samples older than `age` (default 90 days). Returns the number of rows removed.
    @discardableResult
    public func pruneSamples(olderThan age: Duration = DiskMonitor.retention) async throws -> Int {
        let cutoff = now().addingTimeInterval(-TimeInterval(age.components.seconds)).timeIntervalSince1970
        do {
            return try await database.writer.write { db in
                try db.execute(sql: "DELETE FROM disk_sample WHERE sampled_at < ?", arguments: [cutoff])
                return db.changesCount
            }
        } catch {
            throw DiskMonitorError.databaseFailed(reason: error.localizedDescription)
        }
    }

    private func readSample() throws -> DiskSample {
        let capacity: VolumeCapacity
        do {
            capacity = try sampler.sample()
        } catch let error as DiskMonitorError {
            throw error
        } catch {
            throw DiskMonitorError.volumeReadFailed(URL(filePath: "/"), reason: error.localizedDescription)
        }
        return DiskSample(
            sampledAt: now(),
            totalBytes: capacity.total,
            freeBytes: capacity.available,
            importantFree: capacity.importantAvailable,
        )
    }

    private func evaluateThreshold(for sample: DiskSample) {
        guard settings.isEnabled else { return }
        switch tracker.update(importantFree: sample.importantFree, thresholdBytes: settings.thresholdBytes) {
        case .crossedBelow: broadcaster.yield(.crossedBelowThreshold(sample))
        case .recovered: broadcaster.yield(.recovered(sample))
        case nil: break
        }
    }
}
