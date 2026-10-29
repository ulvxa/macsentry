import Foundation

public struct TestAppInventory: AppInventory, AppHelperInventory {
    public var apps: [InstalledApp]
    public var running: Set<String>
    public var helpers: [String: [String]]
    public var runningNames: [String]

    public init(apps: [InstalledApp] = [], running: Set<String> = [], helpers: [String: [String]] = [:], runningNames: [String] = []) {
        self.apps = apps
        self.running = running
        self.helpers = helpers
        self.runningNames = runningNames
    }

    public func installedApps() async -> [InstalledApp] {
        apps
    }

    public func isRunning(bundleID: String) -> Bool {
        running.contains(bundleID)
    }

    public func runningAppNames() -> [String] {
        runningNames
    }

    public func helperBundleIDs(of app: InstalledApp) -> [String] {
        helpers[app.bundleID] ?? []
    }
}
