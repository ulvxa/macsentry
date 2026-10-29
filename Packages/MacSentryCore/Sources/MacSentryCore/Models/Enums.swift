import GRDB

public enum ScanStatus: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case running, finished, cancelled, failed
}

public enum CandidateKind: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case file, folder, package
}

public enum Category: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case devCache, appCache, oldLarge, projectArtifact, orphan, duplicate, flagged
}

public enum Tier: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case green, yellow, red
}

public enum CandidateAction: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case quarantine, flagOnly
}

public enum CandidateStatus: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case found, quarantined, trashed, restored, ignored, stale
}

public enum QuarantineStatus: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case inQuarantine, trashed, restored, missing
}

public enum Confidence: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case high, medium, low
}

public enum AgeBasis: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case lastUsed, modified, created
}
