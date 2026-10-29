import Darwin
import Foundation
import Synchronization

public protocol PermissionService: Sendable {
    func hasFullDiskAccess() -> Bool
    func openFullDiskAccessSettings()
}

public struct SystemPermissionService: PermissionService {
    public static let fullDiskAccessSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
    ) ?? URL(filePath: "/System/Applications/System Settings.app")

    public static let defaultTCCDatabaseURL = URL(filePath: "/Library/Application Support/com.apple.TCC/TCC.db")

    private let homeURL: URL
    private let tccDatabaseURL: URL
    private let openURL: @Sendable (URL) -> Void

    public init(homeURL: URL, tccDatabaseURL: URL = defaultTCCDatabaseURL, openURL: @escaping @Sendable (URL) -> Void) {
        self.homeURL = homeURL
        self.tccDatabaseURL = tccDatabaseURL
        self.openURL = openURL
    }

    public func hasFullDiskAccess() -> Bool {
        canListStocksContainer() || canOpenForReading(tccDatabaseURL)
    }

    public func openFullDiskAccessSettings() {
        openURL(Self.fullDiskAccessSettingsURL)
    }

    private func canListStocksContainer() -> Bool {
        let container = homeURL.appending(path: "Library/Containers/com.apple.stocks", directoryHint: .isDirectory)
        return (try? FileManager.default.contentsOfDirectory(atPath: container.path(percentEncoded: false))) != nil
    }

    private func canOpenForReading(_ url: URL) -> Bool {
        let descriptor = open(url.path(percentEncoded: false), O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }
}

public final class PermissionServiceDouble: PermissionService {
    private struct State {
        var granted: Bool
        var openCount = 0
    }

    private let state: Mutex<State>

    public init(granted: Bool) {
        state = Mutex(State(granted: granted))
    }

    public var granted: Bool {
        get { state.withLock(\.granted) }
        set { state.withLock { $0.granted = newValue } }
    }

    public var openCount: Int {
        state.withLock(\.openCount)
    }

    public func hasFullDiskAccess() -> Bool {
        granted
    }

    public func openFullDiskAccessSettings() {
        state.withLock { $0.openCount += 1 }
    }
}
