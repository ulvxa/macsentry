import Foundation

extension DefaultOrphanDetector {
    struct Identity {
        var value: String
        var unreadable = false
        var program: URL?
    }

    func resolveIdentity(of item: LibraryItem, in location: OrphanLocation) -> Identity {
        switch location {
        case .containers:
            let metadata = Self.plist(at: item.url.appending(path: Self.containerMetadataName))
            if let id = metadata?["MCMMetadataIdentifier"] as? String, !id.isEmpty {
                return Identity(value: id)
            }
            return Identity(value: item.name, unreadable: true)
        case .groupContainers:
            return Identity(value: Self.groupContainerIdentity(item.name))
        case .savedApplicationState, .preferences:
            return Identity(value: item.url.deletingPathExtension().lastPathComponent)
        case .httpStorages:
            let isCookies = item.url.pathExtension == "binarycookies"
            return Identity(value: isCookies ? item.url.deletingPathExtension().lastPathComponent : item.name)
        case .launchAgents:
            let fallback = item.url.deletingPathExtension().lastPathComponent
            guard let plist = Self.plist(at: item.url) else {
                return Identity(value: fallback, unreadable: true)
            }
            let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [Any])?.first as? String
            let label = (plist["Label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Identity(value: label ?? fallback, unreadable: label == nil, program: program.map { URL(filePath: $0) })
        case .applicationSupport, .caches, .webKit, .logs:
            return Identity(value: item.name)
        }
    }

    static func groupContainerIdentity(_ name: String) -> String {
        var identity = Substring(name)
        let teamID = identity.prefix { $0 != "." }
        if teamID.count == 10, teamID.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }), identity.count > 11 {
            identity = identity.dropFirst(11)
        }
        for prefix in ["systemgroup.", "groups.", "group."] where identity.hasPrefix(prefix) && identity.count > prefix.count {
            identity = identity.dropFirst(prefix.count)
            break
        }
        return String(identity)
    }

    static func accepts(_ item: LibraryItem, in location: OrphanLocation) -> Bool {
        switch location {
        case .preferences, .launchAgents:
            !item.isDirectory && item.url.pathExtension == "plist"
        case .savedApplicationState:
            item.isDirectory && item.url.pathExtension == "savedState"
        default:
            true
        }
    }

    static func launchAgentNotes(program: URL?) -> [String] {
        var notes: [String] = []
        if let program {
            let path = program.path(percentEncoded: false)
            notes.append(FileManager.default.fileExists(atPath: path) ? "It runs \(path)." : "It runs \(path), which no longer exists.")
        }
        notes.append("Unload it with the command below, then move the plist to the Trash.")
        return notes
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func plist(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    struct LibraryItem {
        let url: URL
        let name: String
        let isDirectory: Bool
        let isPackage: Bool
        let fileSize: Int64
        let allocatedSize: Int64
        let created: Date?
        let modified: Date?
    }

    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey,
        .creationDateKey, .contentModificationDateKey,
    ]

    static func children(of folder: URL) -> [LibraryItem] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles],
        )) ?? []
        return urls.compactMap { url -> LibraryItem? in
            guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)), values.isSymbolicLink != true else { return nil }
            let name = url.lastPathComponent
            let isDirectory = values.isDirectory == true
            return LibraryItem(
                url: folder.appending(path: name, directoryHint: isDirectory ? .isDirectory : .notDirectory),
                name: name,
                isDirectory: isDirectory,
                isPackage: values.isPackage == true,
                fileSize: Int64(values.fileSize ?? 0),
                allocatedSize: Int64(values.totalFileAllocatedSize ?? 0),
                created: values.creationDate,
                modified: values.contentModificationDate,
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
