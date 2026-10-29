import Foundation

public enum DiskEvent: Sendable, Equatable {
    case sample(DiskSample)
    case crossedBelowThreshold(DiskSample)
    case recovered(DiskSample)
}

public struct ThresholdSettings: Sendable, Equatable {
    public static let defaultThresholdBytes: Int64 = 30_000_000_000

    public var isEnabled: Bool
    public var thresholdBytes: Int64

    public init(isEnabled: Bool = true, thresholdBytes: Int64 = ThresholdSettings.defaultThresholdBytes) {
        self.isEnabled = isEnabled
        self.thresholdBytes = thresholdBytes
    }
}

public struct ThresholdTracker: Sendable, Equatable {
    public enum Transition: Sendable, Equatable {
        case crossedBelow
        case recovered
    }

    public static let hysteresisBytes: Int64 = 5_000_000_000

    public private(set) var isBelow = false

    public init() {}

    public mutating func update(importantFree: Int64, thresholdBytes: Int64) -> Transition? {
        if isBelow {
            guard importantFree > thresholdBytes + Self.hysteresisBytes else { return nil }
            isBelow = false
            return .recovered
        }
        guard importantFree < thresholdBytes else { return nil }
        isBelow = true
        return .crossedBelow
    }

    public mutating func reset() {
        isBelow = false
    }
}
