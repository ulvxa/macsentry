import Foundation

struct UserDataReport: Equatable {
    var markers: [UserDataMarkers.Marker] = []
    var newestDatabaseChange: Date?
    var sidecars: [URL] = []

    var isUserData: Bool {
        !markers.isEmpty
    }

    func isInUse(now: Date) -> Bool {
        guard let newestDatabaseChange else { return false }
        return now.timeIntervalSince(newestDatabaseChange) < UserDataMarkers.inUseInterval
    }

    var note: String? {
        guard !markers.isEmpty else { return nil }
        var seen = Set<UserDataMarkers.Kind>()
        let found = markers.filter { seen.insert($0.kind).inserted }.map { "\($0.kind.label) (\($0.path))" }
        var note = "It looks like it holds your own data: \(found.joined(separator: ", ")). Check it before moving it."
        if !sidecars.isEmpty {
            note += " Its \(sidecars.map(\.lastPathComponent).joined(separator: ", ")) files belong to it and are counted in its size."
        }
        return note
    }
}

enum UserDataMarkers {
    static let maxDepth = 3
    static let maxEntries = 2000
    static let inUseInterval: TimeInterval = 7 * 86400
    static let databaseExtensions: Set<String> = ["sqlite", "sqlite3", "store", "db", "realm"]
    static let sidecarSuffixes = ["-wal", "-shm", "-journal"]

    enum Kind: Hashable {
        case saves, projects, credentials, database

        var label: String {
            switch self {
            case .saves: "saved games"
            case .projects: "projects"
            case .credentials: "credentials or tokens"
            case .database: "a database"
            }
        }
    }

    struct Marker: Equatable {
        let kind: Kind
        let path: String
        let modified: Date?
    }

    private static let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]

    static func inspect(_ url: URL, isDirectory: Bool, modified: Date?, databasesAreUserData: Bool) -> UserDataReport {
        var report = UserDataReport()
        let markers: [Marker]
        if isDirectory {
            markers = scan(url)
        } else {
            report.sidecars = sidecars(of: url)
            let newest = ([modified] + report.sidecars.map(modificationDate)).compactMap(\.self).max()
            markers = kind(of: url.lastPathComponent, isDirectory: false)
                .map { [Marker(kind: $0, path: url.lastPathComponent, modified: newest)] } ?? []
        }
        let databases = markers.filter { $0.kind == .database }
        report.newestDatabaseChange = databases.compactMap(\.modified).max()
        report.markers = databasesAreUserData ? markers : markers.filter { $0.kind != .database }
        return report
    }

    static func kind(of name: String, isDirectory: Bool) -> Kind? {
        let lower = name.lowercased()
        if isDatabase(lower) {
            return .database
        }
        if isDirectory, lower == "saves" {
            return .saves
        }
        if lower.contains("projects") || lower.contains("project library") {
            return .projects
        }
        return isCredential(lower) ? .credentials : nil
    }

    static func isDatabase(_ name: String) -> Bool {
        databaseExtensions.contains((databaseBase(of: name) as NSString).pathExtension.lowercased())
    }

    static func databaseBase(of name: String) -> String {
        let lower = name.lowercased()
        for suffix in sidecarSuffixes where lower.hasSuffix(suffix) && name.count > suffix.count {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    static func isSidecar(_ name: String, among siblings: Set<String>) -> Bool {
        let base = databaseBase(of: name)
        return base != name && isDatabase(base) && siblings.contains(base)
    }

    private static func isCredential(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension
        return name == "credentials" || name.hasPrefix("credentials.") || name.contains("token")
            || ["pem", "yml", "yaml"].contains(ext) || name == ".env" || name.hasPrefix(".env.")
            || ["id_rsa", "id_ed25519", "id_ecdsa"].contains { name.hasPrefix($0) }
    }

    private static func scan(_ folder: URL) -> [Marker] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsPackageDescendants],
        ) else { return [] }
        var markers: [Marker] = []
        var visited = 0
        while visited < maxEntries, let url = enumerator.nextObject() as? URL {
            visited += 1
            let values = try? url.resourceValues(forKeys: Set(resourceKeys))
            let isDirectory = values?.isDirectory == true && values?.isSymbolicLink != true
            if isDirectory, enumerator.level >= maxDepth {
                enumerator.skipDescendants()
            }
            guard let kind = kind(of: url.lastPathComponent, isDirectory: isDirectory) else { continue }
            let relative = url.pathComponents.dropFirst(folder.pathComponents.count).joined(separator: "/")
            markers.append(Marker(kind: kind, path: relative, modified: values?.contentModificationDate))
        }
        return markers
    }

    private static func sidecars(of file: URL) -> [URL] {
        let folder = file.deletingLastPathComponent()
        return sidecarSuffixes
            .map { folder.appending(path: file.lastPathComponent + $0, directoryHint: .notDirectory) }
            .filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    private static func modificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
