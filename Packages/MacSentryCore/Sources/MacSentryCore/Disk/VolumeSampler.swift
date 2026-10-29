import Foundation

public struct VolumeCapacity: Sendable, Equatable {
    public let total: Int64
    public let available: Int64
    public let importantAvailable: Int64

    public init(total: Int64, available: Int64, importantAvailable: Int64) {
        self.total = total
        self.available = available
        self.importantAvailable = importantAvailable
    }
}

public protocol VolumeSampler: Sendable {
    func sample() throws -> VolumeCapacity
}

public enum DiskMonitorError: LocalizedError, Equatable {
    case volumeReadFailed(URL, reason: String)
    case volumeValuesMissing(URL)
    case databaseFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case let .volumeReadFailed(url, reason):
            "Could not read capacity of \(url.path(percentEncoded: false)): \(reason)"
        case let .volumeValuesMissing(url):
            "The volume at \(url.path(percentEncoded: false)) did not report capacity values"
        case let .databaseFailed(reason):
            "Disk sample storage failed: \(reason)"
        }
    }
}

public struct SystemVolumeSampler: VolumeSampler {
    public let volumeURL: URL

    public init(volumeURL: URL = URL(filePath: "/")) {
        self.volumeURL = volumeURL
    }

    public func sample() throws -> VolumeCapacity {
        let values: URLResourceValues
        do {
            values = try volumeURL.resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey,
            ])
        } catch {
            throw DiskMonitorError.volumeReadFailed(volumeURL, reason: error.localizedDescription)
        }
        guard let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacity,
              let important = values.volumeAvailableCapacityForImportantUsage
        else {
            throw DiskMonitorError.volumeValuesMissing(volumeURL)
        }
        return VolumeCapacity(total: Int64(total), available: Int64(available), importantAvailable: important)
    }
}
