import Foundation

public struct DefaultOrphanDetector: OrphanDetector {
    public typealias ApplicationLookup = @Sendable (String) -> URL?
    public typealias RuleClaim = @Sendable (URL) -> Bool
    public typealias FolderSize = @Sendable (URL) async throws -> SizeInfo

    public static let containerMetadataName = ".com.apple.containermanagerd.metadata.plist"
    public static let olderVersionReason = "Settings from an older version"

    private let sessionID: Int64
    private let allowlist: SystemAllowlist
    private let policy: any ProtectionPolicy
    private let helperBundleIDs: Set<String>
    private let applicationURL: ApplicationLookup
    private let isClaimedByRule: RuleClaim
    private let folderSize: FolderSize
    private let now: @Sendable () -> Date

    public init(
        sessionID: Int64,
        allowlist: SystemAllowlist,
        policy: any ProtectionPolicy,
        helperBundleIDs: Set<String> = [],
        applicationURL: @escaping ApplicationLookup,
        isClaimedByRule: @escaping RuleClaim,
        folderSize: @escaping FolderSize,
        now: @escaping @Sendable () -> Date = { Date() },
    ) {
        self.sessionID = sessionID
        self.allowlist = allowlist
        self.policy = policy
        self.helperBundleIDs = helperBundleIDs
        self.applicationURL = applicationURL
        self.isClaimedByRule = isClaimedByRule
        self.folderSize = folderSize
        self.now = now
    }

    public init(
        sessionID: Int64,
        allowlist: SystemAllowlist,
        policy: any ProtectionPolicy,
        helperBundleIDs: Set<String> = [],
        applicationURL: @escaping ApplicationLookup,
        isClaimedByRule: @escaping RuleClaim,
        sizeCalculator: any SizeCalculator,
    ) {
        self.init(
            sessionID: sessionID,
            allowlist: allowlist,
            policy: policy,
            helperBundleIDs: helperBundleIDs,
            applicationURL: applicationURL,
            isClaimedByRule: isClaimedByRule,
            folderSize: { try await sizeCalculator.aggregate(folder: $0) },
        )
    }

    public func findings(inventory: [InstalledApp], library: URL) async throws -> [OrphanFinding] {
        let matcher = Self.matcher(inventory: inventory, helperBundleIDs: helperBundleIDs, allowlist: allowlist)
        var results: [OrphanFinding] = []
        for location in OrphanLocation.allCases {
            try Task.checkCancellation()
            let items = Self.children(of: library.appending(path: location.folderName, directoryHint: .isDirectory))
            let siblings = items.map(\.name)
            let names = Set(siblings)
            for item in items where Self.accepts(item, in: location) && !UserDataMarkers.isSidecar(item.name, among: names) {
                try Task.checkCancellation()
                results += try await evaluate(item, location: location, siblings: siblings, matcher: matcher)
            }
        }
        return results
    }

    private func evaluate(
        _ item: LibraryItem,
        location: OrphanLocation,
        siblings: [String],
        matcher: OrphanMatcher,
    ) async throws -> [OrphanFinding] {
        guard isEligible(item.url) else { return [] }
        let identity = Self.resolveIdentity(of: item.url, name: item.name, in: location)

        if matcher.isSystem(item.name) || matcher.isSystem(identity.value) {
            guard !item.name.lowercased().hasPrefix("com.apple.") else { return [] }
            return try await olderVersions(inside: item, location: location, matcher: matcher)
        }
        if location.checksVersionFolders,
           let older = matcher.olderVersion(name: item.name, parent: nil, siblings: siblings) {
            return await olderVersionFinding(item, location: location, older: older).map { [$0] } ?? []
        }
        if Self.isOwned(identity, matcher: matcher, applicationURL: applicationURL) {
            return try await olderVersions(inside: item, location: location, matcher: matcher)
        }
        return await orphanFinding(item, location: location, identity: identity, matcher: matcher).map { [$0] } ?? []
    }

    private func isEligible(_ url: URL) -> Bool {
        policy.check(url) == .allowed && !isClaimedByRule(url)
    }

    static func matcher(inventory: [InstalledApp], helperBundleIDs: Set<String>, allowlist: SystemAllowlist) -> OrphanMatcher {
        OrphanMatcher(
            apps: inventory,
            extraIDs: helperBundleIDs.union(AppHelperIdentifiers.collect(from: inventory)),
            allowlist: allowlist,
            appleTokens: AppleAppIdentifiers.collect(from: inventory),
        )
    }

    static func isOwned(_ identity: Identity, matcher: OrphanMatcher, applicationURL: ApplicationLookup) -> Bool {
        if matcher.isKnownID(identity.value) || matcher.matchesKnownName(identity.value) {
            return true
        }
        if let program = identity.program, matcher.isInsideInstalledApp(program) {
            return true
        }
        return OrphanMatcher.isReverseDNS(identity.value) && applicationURL(identity.value) != nil
    }

    private func olderVersions(
        inside item: LibraryItem,
        location: OrphanLocation,
        matcher: OrphanMatcher,
    ) async throws -> [OrphanFinding] {
        guard location.checksVersionFolders, item.isDirectory, !item.isPackage else { return [] }
        let children = Self.children(of: item.url)
        let siblings = children.map(\.name)
        var results: [OrphanFinding] = []
        for child in children where child.isDirectory && !child.isPackage {
            try Task.checkCancellation()
            guard let older = matcher.olderVersion(name: child.name, parent: item.name, siblings: siblings),
                  isEligible(child.url),
                  let finding = await olderVersionFinding(child, location: location, older: older)
            else { continue }
            results.append(finding)
        }
        return results
    }

    private func olderVersionFinding(_ item: LibraryItem, location: OrphanLocation, older: OlderVersion) async -> OrphanFinding? {
        let userData = Self.inspectUserData(item, location: location)
        guard !userData.isInUse(now: now()) else { return nil }
        let current = "\(older.app.name) \(older.currentVersion) is installed."
        let notes = ["This folder is for \(older.product) \(older.folderVersion).", current] + [userData.note].compactMap(\.self)
        let explanation = OrphanExplanation(
            kind: .olderVersion(product: older.product, folderVersion: older.folderVersion, currentVersion: older.currentVersion),
            identity: item.name,
            guessedAppName: older.app.name,
            failedChecks: [],
            notes: notes,
        )
        var candidate = await makeCandidate(
            item,
            location: location,
            ruleID: "orphan.oldVersion",
            reason: ([Self.olderVersionReason + ". " + current] + [userData.note].compactMap(\.self)).joined(separator: " "),
            confidence: userData.isUserData ? .low : .medium,
        )
        Self.apply(userData, to: &candidate)
        candidate.appBundleID = older.app.bundleID
        return OrphanFinding(candidate: candidate, location: location, explanation: explanation)
    }

    private func orphanFinding(
        _ item: LibraryItem,
        location: OrphanLocation,
        identity: Identity,
        matcher: OrphanMatcher,
    ) async -> OrphanFinding? {
        let userData = Self.inspectUserData(item, location: location)
        guard !userData.isInUse(now: now()) else { return nil }
        let checks = OrphanCheck.allCases.filter { $0 != .launchServices || OrphanMatcher.isReverseDNS(identity.value) }
        var confidence = matcher.confidence(for: identity.value)
        var notes: [String] = []
        if identity.unreadable {
            confidence = .low
            notes.append(location == .containers
                ? "The container metadata could not be read, so the owner is a guess from the folder name."
                : "The plist could not be read, so the owner is a guess from the file name.")
        }
        notes += [Self.confidenceNote(confidence, identity: identity, matcher: matcher)].compactMap(\.self)
        if let note = userData.note {
            confidence = .low
            notes.append(note)
        }

        if location == .launchAgents {
            notes += Self.launchAgentNotes(program: identity.program)
        }

        let explanation = OrphanExplanation(
            kind: .noInstalledApp,
            identity: identity.value,
            guessedAppName: OrphanMatcher.guessedAppName(for: identity.value),
            failedChecks: checks,
            notes: notes,
        )
        let reason = "No installed app owns \"\(identity.value)\": "
            + checks.map(\.failureDescription).joined(separator: ", ")
            + ". " + notes.joined(separator: " ")
        var candidate = await makeCandidate(item, location: location, ruleID: location.ruleID, reason: reason, confidence: confidence)
        Self.apply(userData, to: &candidate)
        candidate.appBundleID = OrphanMatcher.isReverseDNS(identity.value) ? identity.value : nil
        if location == .launchAgents {
            candidate.cliCommand = "launchctl bootout gui/$(id -u) \(Self.shellQuoted(item.url.path(percentEncoded: false)))"
        }
        return OrphanFinding(candidate: candidate, location: location, explanation: explanation)
    }

    private func makeCandidate(
        _ item: LibraryItem,
        location: OrphanLocation,
        ruleID: String,
        reason: String,
        confidence: Confidence,
    ) async -> Candidate {
        let size: SizeInfo = if item.isDirectory {
            await (try? folderSize(item.url)) ?? SizeInfo(logical: 0, allocated: 0, freeable: 0)
        } else {
            SizeInfo(logical: item.fileSize, allocated: item.allocatedSize, freeable: item.allocatedSize)
        }
        return Candidate(
            sessionID: sessionID,
            url: item.url,
            kind: item.isPackage ? .package : item.isDirectory ? .folder : .file,
            category: .orphan,
            ruleID: ruleID,
            tier: location.tier,
            action: location.action,
            reason: reason,
            logicalSize: size.logical,
            allocatedSize: size.allocated,
            freeableSize: size.freeable,
            createdAt: item.created,
            modifiedAt: item.modified,
            confidence: confidence,
        )
    }
}
