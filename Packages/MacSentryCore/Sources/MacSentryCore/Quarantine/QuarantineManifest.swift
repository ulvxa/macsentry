import Foundation

struct QuarantineManifest: Codable, Equatable {
    static let currentVersion = 1

    struct Entry: Codable, Equatable {
        var originalPath: String
        var quarantinePath: String
        var kind: CandidateKind
        var ruleId: String
        var tier: Tier
        var size: Int64
        var status: QuarantineStatus

        init(_ entry: QuarantineEntry) {
            originalPath = entry.originalURL.storagePath
            quarantinePath = entry.quarantineURL.storagePath
            kind = entry.kind
            ruleId = entry.ruleID
            tier = entry.tier
            size = entry.size
            status = entry.status
        }
    }

    var version: Int
    var batch: String
    var createdAt: String
    var dryRun: Bool
    var entries: [Entry]

    init(batch: QuarantineBatch, entries: [QuarantineEntry], timeZone: TimeZone) {
        version = Self.currentVersion
        self.batch = batch.folderName
        createdAt = Self.dateStyle(timeZone).format(batch.createdAt)
        dryRun = batch.dryRun
        self.entries = entries.map(Entry.init)
    }

    func createdDate(timeZone: TimeZone) -> Date? {
        try? Self.dateStyle(timeZone).parse(createdAt)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> QuarantineManifest {
        try JSONDecoder().decode(QuarantineManifest.self, from: data)
    }

    private static func dateStyle(_ timeZone: TimeZone) -> Date.ISO8601FormatStyle {
        Date.ISO8601FormatStyle(timeZoneSeparator: .colon, timeZone: timeZone)
    }
}
