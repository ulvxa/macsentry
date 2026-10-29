import Foundation

public protocol OrphanDetector: Sendable {
    func detect(inventory: [InstalledApp], library: URL) async throws -> [Candidate]
    func findings(inventory: [InstalledApp], library: URL) async throws -> [OrphanFinding]
}

public extension OrphanDetector {
    func detect(inventory: [InstalledApp], library: URL) async throws -> [Candidate] {
        try await findings(inventory: inventory, library: library).map(\.candidate)
    }
}

public enum OrphanLocation: String, Sendable, CaseIterable {
    case applicationSupport
    case caches
    case containers
    case groupContainers
    case savedApplicationState
    case httpStorages
    case webKit
    case logs
    case preferences
    case launchAgents

    public var folderName: String {
        switch self {
        case .applicationSupport: "Application Support"
        case .caches: "Caches"
        case .containers: "Containers"
        case .groupContainers: "Group Containers"
        case .savedApplicationState: "Saved Application State"
        case .httpStorages: "HTTPStorages"
        case .webKit: "WebKit"
        case .logs: "Logs"
        case .preferences: "Preferences"
        case .launchAgents: "LaunchAgents"
        }
    }

    public var ruleID: String {
        "orphan.\(rawValue)"
    }

    public var tier: Tier {
        switch self {
        case .applicationSupport, .containers, .groupContainers: .yellow
        case .caches, .savedApplicationState, .httpStorages, .webKit, .logs, .preferences: .green
        case .launchAgents: .red
        }
    }

    public var action: CandidateAction {
        self == .launchAgents ? .flagOnly : .quarantine
    }

    var checksVersionFolders: Bool {
        switch self {
        case .applicationSupport, .caches, .logs: true
        default: false
        }
    }

    /// Caches and HTTPStorages keep throwaway Cache.db files; a fresh one still means the owner is alive.
    var databasesAreUserData: Bool {
        self != .caches && self != .httpStorages
    }
}

public enum OrphanCheck: String, Sendable, CaseIterable {
    case installedBundleID
    case installedAppName
    case systemFolder
    case claimedByRule
    case launchServices

    public var failureDescription: String {
        switch self {
        case .installedBundleID: "no installed app or helper has this bundle id"
        case .installedAppName: "the name matches no installed app"
        case .systemFolder: "it is not a system folder"
        case .claimedByRule: "no cleanup rule claims it"
        case .launchServices: "LaunchServices knows no app for it"
        }
    }
}

public struct OrphanExplanation: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case noInstalledApp
        case olderVersion(product: String, folderVersion: String, currentVersion: String)
    }

    public let kind: Kind
    public let identity: String
    public let guessedAppName: String
    public let failedChecks: [OrphanCheck]
    public let notes: [String]

    public init(kind: Kind, identity: String, guessedAppName: String, failedChecks: [OrphanCheck], notes: [String]) {
        self.kind = kind
        self.identity = identity
        self.guessedAppName = guessedAppName
        self.failedChecks = failedChecks
        self.notes = notes
    }
}

public extension OrphanExplanation {
    static func guessedAppName(for identity: String) -> String {
        OrphanMatcher.guessedAppName(for: identity)
    }
}

public struct OrphanFinding: Sendable, Equatable {
    public let candidate: Candidate
    public let location: OrphanLocation
    public let explanation: OrphanExplanation

    public init(candidate: Candidate, location: OrphanLocation, explanation: OrphanExplanation) {
        self.candidate = candidate
        self.location = location
        self.explanation = explanation
    }
}

public struct StubOrphanDetector: OrphanDetector {
    public var result: Result<[OrphanFinding], OrphanDetectorError>

    public init(findings: [OrphanFinding] = []) {
        result = .success(findings)
    }

    public init(error: OrphanDetectorError) {
        result = .failure(error)
    }

    public func findings(inventory _: [InstalledApp], library _: URL) async throws -> [OrphanFinding] {
        try result.get()
    }
}
