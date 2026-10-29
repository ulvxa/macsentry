import Foundation
import MacSentryCore

extension AppModel {
    var isScanning: Bool {
        if case .scanning = scanState {
            true
        } else {
            false
        }
    }

    var isCancellingScan: Bool {
        if case .cancelling = scanState {
            true
        } else {
            false
        }
    }

    var scanActivity: ScanActivity? {
        switch scanState {
        case let .scanning(activity), let .cancelling(activity): activity
        case .idle, .finished, .cancelled, .failed: nil
        }
    }

    var canStartScan: Bool {
        services != nil && scanActivity == nil
    }

    var statusOverlay: StatusOverlay {
        if let activity = scanActivity {
            return .hud(activity)
        }
        if let toast {
            return .toast(toast)
        }
        return .none
    }

    var scanOptions: ScanPipelineOptions {
        let store = settings.store
        return ScanPipelineOptions(
            thresholds: settings.thresholds,
            disabledGroups: Set(store.disabledProfileGroups),
            projectRoots: store.projectRoots,
            duplicateRoots: store.duplicateRoots,
            duplicateMinSize: store.duplicateMinSizeBytes,
        )
    }

    func startScan() {
        guard let services, canStartScan else { return }
        let config = services.scanConfig(settings.scanRoots)
        let control = ScanControl()
        let stream = services.makeScanService(scanOptions, control).scan(config: config)
        toast = nil
        scanState = .scanning(ScanActivity())
        scanControl = control
        hashingTask?.cancel()
        hashingTask = Task { [weak self] in
            for await progress in control.hashingProgress {
                self?.applyHashing(progress)
            }
        }
        scanTask = Task { [weak self] in
            await self?.consume(stream, control: control)
        }
    }

    func skipDuplicates() {
        guard let scanControl, case var .scanning(activity) = scanState, !activity.duplicatesSkipped else { return }
        scanControl.skipDuplicates()
        activity.duplicatesSkipped = true
        scanState = .scanning(activity)
    }

    /// Stays cancelling until the scan stream ends, so a new scan never overlaps the old one's final writes.
    func cancelScan() {
        guard case let .scanning(activity) = scanState else { return }
        scanState = .cancelling(activity)
        if scanControl?.cancel() != true {
            scanTask?.cancel()
        }
    }

    /// Waits for the running scan task. Tests use it; the UI never blocks on a scan.
    func waitForScan() async {
        await scanTask?.value
    }

    func dismissToast(_ id: Toast.ID? = nil) {
        guard id == nil || toast?.id == id else { return }
        toast = nil
    }

    func performToastAction() {
        guard let toast else { return }
        if let action = toast.action {
            selection = action.destination
        }
        self.toast = nil
    }

    private func consume(_ stream: AsyncThrowingStream<ScanEvent, Error>, control: ScanControl) async {
        defer { release(control) }
        do {
            for try await event in stream {
                switch event {
                case let .finished(summary):
                    await complete(summary)
                    return
                case .started:
                    apply(event)
                    await reloadSessions(preferring: nil)
                default:
                    apply(event)
                }
            }
        } catch {
            if !isCancellingScan, !Task.isCancelled {
                runningSessionID = nil
                scanState = .failed(error.localizedDescription)
                toast = Toast(kind: .scanFailed(error.localizedDescription))
                await reloadSessions(preferring: nil)
                return
            }
        }
        runningSessionID = nil
        scanState = .cancelled
        await reloadSessions(preferring: nil)
        toast = Toast(kind: .scanCancelled(hasPreviousResults: currentSessionID != nil))
    }

    private func apply(_ event: ScanEvent) {
        guard case var .scanning(activity) = scanState else { return }
        switch event {
        case let .started(sessionID):
            runningSessionID = sessionID
            activity.sessionID = sessionID
        case let .progress(files, bytes, path):
            activity.filesVisited = files
            activity.bytesVisited = bytes
            if !path.isEmpty {
                activity.currentPath = path
            }
        case let .phase(phase):
            activity.phase = phase
            if phase == .lastUsed {
                activity.hashing = nil
            }
        case .candidates, .finished:
            return
        }
        scanState = .scanning(activity)
    }

    private func applyHashing(_ progress: HashingProgress) {
        guard case var .scanning(activity) = scanState, activity.phase != .lastUsed else { return }
        activity.hashing = progress
        scanState = .scanning(activity)
    }

    private func release(_ control: ScanControl) {
        guard scanControl === control else { return }
        hashingTask?.cancel()
        hashingTask = nil
        scanControl = nil
    }

    private func complete(_ summary: ScanSummary) async {
        runningSessionID = nil
        switch summary.status {
        case .finished:
            duplicatesSkippedSessionID = scanControl?.isDuplicatesSkipped == true ? summary.sessionID : nil
            scanState = .finished(summary)
            toast = Toast(kind: .scanFinished(summary), action: ToastAction(title: "Review", destination: .overview))
            await reloadSessions(preferring: summary.sessionID)
            await menuBar.refreshTotals()
            await refreshLocalSnapshots()
        case .cancelled, .running:
            scanState = .cancelled
            await reloadSessions(preferring: nil)
            toast = Toast(kind: .scanCancelled(hasPreviousResults: currentSessionID != nil))
        case .failed:
            scanState = .failed("The scan stopped before it finished.")
            toast = Toast(kind: .scanFailed("The scan stopped before it finished."))
            await reloadSessions(preferring: nil)
        }
    }
}
