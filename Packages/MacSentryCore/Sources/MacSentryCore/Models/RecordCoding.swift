import Foundation
import GRDB

public protocol UnixTimestampRecord: FetchableRecord, EncodableRecord {}

public extension UnixTimestampRecord {
    static func databaseDateDecodingStrategy(for _: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }

    static func databaseDateEncodingStrategy(for _: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSince1970
    }
}

extension URL {
    init(storagePath: String) {
        self.init(filePath: storagePath)
    }

    var storagePath: String {
        let path = standardizedFileURL.path(percentEncoded: false)
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }
}
