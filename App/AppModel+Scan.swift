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

    var scanActivity: ScanActivity? {
        if case let .scanning(activity) = scanState {
            activity
        } else {
            nil
        }
    }

    var canStartScan: Bool {
        services != nil && !isScanning
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
        guard let services, !isScanning else { return }
        let config = services.scanConfig(settings.scanRoots)
        let stream = services.makeScanService(scanOptions).scan(config: config)
        toast = nil
        scanState = .scanning(ScanActivity())
        scanTask = Task { [weak self] in
            await self?.consume(stream)
        }
    }

    func cancelScan() {
        guard isScanning else { return }
        scanTask?.cancel()
        scanTask = nil
        runningSessionID = nil
        scanState = .cancelled
        toast = Toast(kind: .scanCancelled(hasPreviousResults: currentSessionID != nil))
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

    private func consume(_ stream: AsyncThrowingStream<ScanEvent, Error>) async {
        do {
            for try await event in stream {
                if Task.isCancelled {
                    return
                }
                if case let .finished(summary) = event {
                    await complete(summary)
                    return
                }
                apply(event)
            }
        } catch {
            guard !Task.isCancelled else { return }
            runningSessionID = nil
            scanState = .failed(error.localizedDescription)
            toast = Toast(kind: .scanFailed(error.localizedDescription))
            return
        }
        guard !Task.isCancelled, isScanning else { return }
        runningSessionID = nil
        scanState = .cancelled
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
        case .candidates, .finished:
            return
        }
        scanState = .scanning(activity)
    }

    private func complete(_ summary: ScanSummary) async {
        runningSessionID = nil
        switch summary.status {
        case .finished:
            scanState = .finished(summary)
            toast = Toast(kind: .scanFinished(summary), action: ToastAction(title: "Review", destination: .overview))
            await reloadSessions(preferring: summary.sessionID)
        case .cancelled, .running:
            scanState = .cancelled
            toast = Toast(kind: .scanCancelled(hasPreviousResults: currentSessionID != nil))
        case .failed:
            scanState = .failed("The scan stopped before it finished.")
            toast = Toast(kind: .scanFailed("The scan stopped before it finished."))
        }
    }
}
