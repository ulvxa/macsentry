import Foundation

public struct SystemAllowlist: Sendable, Equatable, Decodable {
    public struct Entry: Sendable, Equatable, Decodable {
        public let name: String
        public let whenInstalledBundleIDPrefix: String?

        public init(name: String, whenInstalledBundleIDPrefix: String? = nil) {
            self.name = name
            self.whenInstalledBundleIDPrefix = whenInstalledBundleIDPrefix
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case name, whenInstalledBundleIDPrefix
        }

        public init(from decoder: any Decoder) throws {
            try decoder.rejectUnknownKeys(CodingKeys.allCases.map(\.rawValue))
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            whenInstalledBundleIDPrefix = try container.decodeIfPresent(String.self, forKey: .whenInstalledBundleIDPrefix)
        }
    }

    public static let supportedVersion = 1

    public let version: Int
    public let entries: [Entry]

    public init(entries: [Entry]) {
        version = Self.supportedVersion
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, entries
    }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.allCases.map(\.rawValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        entries = try container.decode([Entry].self, forKey: .entries)
    }

    public init(data: Data) throws {
        let decoded: SystemAllowlist
        do {
            decoded = try JSONDecoder().decode(SystemAllowlist.self, from: data)
        } catch {
            throw OrphanDetectorError.allowlistInvalid(reason: String(describing: error))
        }
        try decoded.validate()
        self = decoded
    }

    public static func bundled() throws -> SystemAllowlist {
        guard let url = Bundle.module.url(forResource: "Rules", withExtension: nil)?
            .appending(path: "system-allowlist.json"),
            let data = try? Data(contentsOf: url)
        else {
            throw OrphanDetectorError.allowlistMissing
        }
        return try SystemAllowlist(data: data)
    }

    public func activeNames(installedBundleIDs: some Sequence<String>) -> Set<String> {
        let installed = installedBundleIDs.map { $0.lowercased() }
        return Set(entries.compactMap { entry in
            guard let prefix = entry.whenInstalledBundleIDPrefix?.lowercased() else { return entry.name.lowercased() }
            return installed.contains { $0.hasPrefix(prefix) } ? entry.name.lowercased() : nil
        })
    }

    private func validate() throws {
        guard version == Self.supportedVersion else {
            throw OrphanDetectorError.allowlistInvalid(reason: "unsupported version \(version)")
        }
        var seen = Set<String>()
        for entry in entries {
            let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name == entry.name else {
                throw OrphanDetectorError.allowlistInvalid(reason: "entry name \"\(entry.name)\" is empty or padded")
            }
            guard seen.insert(name.lowercased()).inserted else {
                throw OrphanDetectorError.allowlistInvalid(reason: "duplicate entry \"\(name)\"")
            }
            if let prefix = entry.whenInstalledBundleIDPrefix, prefix.isEmpty {
                throw OrphanDetectorError.allowlistInvalid(reason: "entry \"\(name)\" has an empty bundle id prefix")
            }
        }
    }
}

private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue _: Int) {
        nil
    }
}

private extension Decoder {
    func rejectUnknownKeys(_ allowed: [String]) throws {
        let container = try container(keyedBy: AnyCodingKey.self)
        let unknown = container.allKeys.map(\.stringValue).filter { !allowed.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: codingPath, debugDescription: "Unknown keys: \(unknown.joined(separator: ", "))"),
            )
        }
    }
}
