import Foundation
#if canImport(AppKit)
    import AppKit
#endif

public protocol AppHelperInventory: Sendable {
    func helperBundleIDs(of app: InstalledApp) -> [String]
}

public struct SystemAppInventory: AppInventory, AppHelperInventory {
    static let helperFolders = ["Contents/Library/LoginItems", "Contents/Helpers", "Contents/Frameworks"]

    public let appRoots: [URL]
    public let editorRoots: [URL]
    private let runningBundleIDs: @Sendable () -> Set<String>
    private let runningNames: @Sendable () -> [String]

    public init(
        appRoots: [URL],
        editorRoots: [URL] = [],
        runningBundleIDs: @escaping @Sendable () -> Set<String> = SystemAppInventory.liveRunningBundleIDs,
        runningAppNames: @escaping @Sendable () -> [String] = SystemAppInventory.liveRunningAppNames,
    ) {
        self.appRoots = appRoots
        self.editorRoots = editorRoots
        self.runningBundleIDs = runningBundleIDs
        runningNames = runningAppNames
    }

    public static func standard(homeURL: URL) -> SystemAppInventory {
        let applications = URL(filePath: "/Applications", directoryHint: .isDirectory)
        let systemApplications = URL(filePath: "/System/Applications", directoryHint: .isDirectory)
        return SystemAppInventory(
            appRoots: [
                applications,
                applications.appending(path: "Utilities", directoryHint: .isDirectory),
                homeURL.appending(path: "Applications", directoryHint: .isDirectory),
                systemApplications,
                systemApplications.appending(path: "Utilities", directoryHint: .isDirectory),
                URL(filePath: "/System/Library/CoreServices", directoryHint: .isDirectory),
            ],
            editorRoots: [applications.appending(path: "Unity/Hub/Editor", directoryHint: .isDirectory)],
        )
    }

    public func installedApps() async -> [InstalledApp] {
        var seen = Set<String>()
        var apps: [InstalledApp] = []
        func add(_ url: URL) {
            guard seen.insert(url.storagePath).inserted, let app = Self.readApp(at: url) else { return }
            apps.append(app)
        }
        for root in appRoots {
            for child in Self.directories(in: root) {
                if Self.isApp(child) {
                    add(child)
                } else {
                    Self.directories(in: child).filter(Self.isApp).forEach(add)
                }
            }
        }
        for root in editorRoots {
            for version in Self.directories(in: root) {
                Self.directories(in: version).filter(Self.isApp).forEach(add)
            }
        }
        return apps
    }

    public func isRunning(bundleID: String) -> Bool {
        runningBundleIDs().contains(bundleID)
    }

    public func runningAppNames() -> [String] {
        runningNames()
    }

    public func helperBundleIDs(of app: InstalledApp) -> [String] {
        var seen = Set<String>()
        return Self.helperFolders
            .flatMap { Self.directories(in: app.url.appending(path: $0, directoryHint: .isDirectory)).filter(Self.isApp) }
            .compactMap { Self.readApp(at: $0)?.bundleID }
            .filter { $0 != app.bundleID && seen.insert($0).inserted }
    }

    public static let liveRunningBundleIDs: @Sendable () -> Set<String> = {
        #if canImport(AppKit)
            Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        #else
            []
        #endif
    }

    public static let liveRunningAppNames: @Sendable () -> [String] = {
        #if canImport(AppKit)
            NSWorkspace.shared.runningApplications.flatMap { [$0.localizedName, $0.executableURL?.lastPathComponent].compactMap(\.self) }
        #else
            []
        #endif
    }

    static func readApp(at url: URL) -> InstalledApp? {
        let plistURL = url.appending(path: "Contents/Info.plist", directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String, !bundleID.isEmpty
        else { return nil }
        let fileName = url.deletingPathExtension().lastPathComponent
        let name = [plist["CFBundleName"], plist["CFBundleDisplayName"]]
            .compactMap { $0 as? String }
            .first { !$0.isEmpty } ?? fileName
        return InstalledApp(
            bundleID: bundleID,
            name: name,
            version: plist["CFBundleShortVersionString"] as? String,
            url: url,
            executable: (plist["CFBundleExecutable"] as? String).flatMap { $0.isEmpty ? nil : $0 },
        )
    }

    private static func isApp(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "app"
    }

    private static func directories(in folder: URL) -> [URL] {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles],
        )
        return (contents ?? [])
            .filter {
                let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values?.isDirectory == true && values?.isSymbolicLink != true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
