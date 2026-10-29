import Foundation
import MacSentryCore
import MacSentryTestSupport

struct AllowAllPolicy: ProtectionPolicy {
    func check(_: URL) -> ProtectionVerdict {
        .allowed
    }
}

struct DenyNamesPolicy: ProtectionPolicy {
    let names: Set<String>

    func check(_ url: URL) -> ProtectionVerdict {
        names.contains(url.lastPathComponent) ? .denied("protected") : .allowed
    }
}

struct OrphanFixture {
    static let folderSize = SizeInfo(logical: 1000, allocated: 4096, freeable: 4096)

    let fixture: FixtureBuilder
    let library: URL

    init() throws {
        fixture = try FixtureBuilder(name: "Orphans")
        library = try fixture.folder("home/Library")
    }

    @discardableResult
    func folder(_ relativePath: String) throws -> URL {
        try fixture.folder("home/Library/\(relativePath)")
    }

    @discardableResult
    func file(_ relativePath: String, size: Int64 = 0) throws -> URL {
        try fixture.file("home/Library/\(relativePath)", size: size)
    }

    @discardableResult
    func plist(_ relativePath: String, _ contents: [String: Any]) throws -> URL {
        try write(PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0), to: "home/Library/\(relativePath)")
    }

    @discardableResult
    func rawFile(_ relativePath: String, _ data: Data) throws -> URL {
        try write(data, to: "home/Library/\(relativePath)")
    }

    func app(
        _ name: String,
        bundleID: String,
        version: String? = nil,
        helpers: [String: String] = [:],
    ) throws -> InstalledApp {
        let appPath = "Applications/\(name).app"
        try write(infoPlist(bundleID), to: "\(appPath)/Contents/Info.plist")
        for (folder, helperID) in helpers {
            try write(infoPlist(helperID), to: "\(appPath)/Contents/\(folder)/Helper-\(helperID).app/Contents/Info.plist")
        }
        return try InstalledApp(bundleID: bundleID, name: name, version: version, url: fixture.url(appPath))
    }

    func detector(
        policy: any ProtectionPolicy = AllowAllPolicy(),
        helperBundleIDs: Set<String> = [],
        knownToLaunchServices: Set<String> = [],
        claimed: Set<URL> = [],
    ) throws -> DefaultOrphanDetector {
        let claimedPaths = Set(claimed.map(Self.pathKey))
        return try DefaultOrphanDetector(
            sessionID: 7,
            allowlist: SystemAllowlist.bundled(),
            policy: policy,
            helperBundleIDs: helperBundleIDs,
            applicationURL: { id in
                knownToLaunchServices.contains(id) ? URL(filePath: "/Applications/\(id).app") : nil
            },
            isClaimedByRule: { claimedPaths.contains(Self.pathKey($0)) },
            folderSize: { _ in Self.folderSize },
        )
    }

    static func pathKey(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private func infoPlist(_ bundleID: String) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": bundleID], format: .xml, options: 0)
    }

    @discardableResult
    private func write(_ data: Data, to relativePath: String) throws -> URL {
        let url = try fixture.file(relativePath)
        try data.write(to: url)
        return url
    }
}

extension [OrphanFinding] {
    var names: Set<String> {
        Set(map(\.candidate.url.lastPathComponent))
    }

    func finding(named name: String) -> OrphanFinding? {
        first { $0.candidate.url.lastPathComponent == name }
    }
}
