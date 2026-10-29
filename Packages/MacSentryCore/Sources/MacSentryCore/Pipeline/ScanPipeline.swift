import Foundation

public struct ScanPipelineOptions: Sendable, Equatable {
    public var thresholds: Thresholds
    public var disabledGroups: Set<String>
    public var projectRoots: [URL]
    public var duplicateRoots: [URL]
    public var duplicateMinSize: Int64

    public init(
        thresholds: Thresholds = Thresholds(),
        disabledGroups: Set<String> = [],
        projectRoots: [URL] = [],
        duplicateRoots: [URL] = [],
        duplicateMinSize: Int64 = 1_000_000,
    ) {
        self.thresholds = thresholds
        self.disabledGroups = disabledGroups
        self.projectRoots = projectRoots
        self.duplicateRoots = duplicateRoots
        self.duplicateMinSize = duplicateMinSize
    }
}

public struct ScanPipeline: Sendable {
    public typealias ApplicationLookup = DefaultOrphanDetector.ApplicationLookup

    public let environment: AppEnvironment
    public let database: Database
    public let protection: ProtectionPolicyProvider
    public let inventory: any AppInventory & AppHelperInventory
    public let applicationURL: ApplicationLookup
    let projectScanner: any ProjectScanner
    let lastUsedResolver: any LastUsedResolver
    let walker: (any ReportingFileWalker)?
    let duplicateFinder: any DuplicateFinder
    let ruleCatalog: RuleCatalog?
    let ruleFileSystem: RuleFileSystem
    let progressInterval: Duration

    public init(
        environment: AppEnvironment,
        database: Database,
        protection: ProtectionPolicyProvider,
        inventory: any AppInventory & AppHelperInventory,
        applicationURL: @escaping ApplicationLookup = { _ in nil },
        projectScanner: any ProjectScanner = DefaultProjectScanner(),
        lastUsedResolver: any LastUsedResolver = SpotlightLastUsedResolver(),
        walker: (any ReportingFileWalker)? = nil,
        duplicateFinder: any DuplicateFinder = DefaultDuplicateFinder(),
        ruleCatalog: RuleCatalog? = nil,
        ruleFileSystem: RuleFileSystem = .live,
        progressInterval: Duration = .milliseconds(100),
    ) {
        _ = ProcessClock.launched
        self.environment = environment
        self.database = database
        self.protection = protection
        self.inventory = inventory
        self.applicationURL = applicationURL
        self.projectScanner = projectScanner
        self.lastUsedResolver = lastUsedResolver
        self.walker = walker
        self.duplicateFinder = duplicateFinder
        self.ruleCatalog = ruleCatalog
        self.ruleFileSystem = ruleFileSystem
        self.progressInterval = progressInterval
    }

    public static func isKnownArtifact(in catalog: ArtifactCatalog = .default) -> ArtifactPredicate {
        let suffixes = Set(catalog.rules.map(\.components))
        return { url in
            let components = url.pathComponents
            return suffixes.contains { components.count >= $0.count && Array(components.suffix($0.count)) == $0 }
        }
    }

    public var quarantineFolder: URL {
        environment.homeURL.appending(path: DefaultProtectionPolicy.quarantineFolderName, directoryHint: .isDirectory)
    }

    public func config(scanRoots: [URL]) -> ScanConfig {
        var config = ScanConfig(environment: environment, quarantineFolder: quarantineFolder)
        if environment.scanRoot == nil, !scanRoots.isEmpty {
            config.roots = scanRoots
        }
        return config
    }

    public func makeService(options: ScanPipelineOptions, control: ScanControl = ScanControl()) -> any ScanService {
        PipelineScanService(pipeline: self, options: options, control: control)
    }

    public func activeRules(disabledGroups: Set<String> = []) async throws -> [Rule] {
        let engine = try DefaultRuleEngine(catalog: loadCatalog(), homeURL: environment.homeURL, fileSystem: ruleFileSystem)
        return await engine.activeRules(
            inventory: inventory.installedApps(),
            disabledGroups: disabledGroups,
            existingPaths: ruleFileSystem.itemExists,
        )
    }

    func prepare(_ options: ScanPipelineOptions, control: ScanControl) async throws -> PreparedScan {
        protection.setKnownArtifact(Self.isKnownArtifact())
        do {
            try await protection.refresh()
        } catch {
            throw ScanPipelineError.protectionUnavailable(error.localizedDescription)
        }
        try await failStaleSessions()

        let catalog = try loadCatalog()
        let allowlist: SystemAllowlist
        do {
            allowlist = try SystemAllowlist.bundled()
        } catch {
            throw ScanPipelineError.catalogUnavailable(error.localizedDescription)
        }
        let apps = await inventory.installedApps()
        let engine = DefaultRuleEngine(catalog: catalog, homeURL: environment.homeURL, fileSystem: ruleFileSystem)
        let rules = engine.compile(engine.activeRules(
            inventory: apps,
            disabledGroups: options.disabledGroups,
            existingPaths: ruleFileSystem.itemExists,
        ))
        return PreparedScan(
            pipeline: self,
            options: options,
            control: control,
            apps: apps,
            helperBundleIDs: Set(apps.flatMap(inventory.helperBundleIDs(of:))),
            allowlist: allowlist,
            engine: engine,
            rules: rules,
        )
    }

    private func loadCatalog() throws -> RuleCatalog {
        if let ruleCatalog {
            return ruleCatalog
        }
        do {
            return try RuleCatalog.bundled()
        } catch {
            throw ScanPipelineError.catalogUnavailable(error.localizedDescription)
        }
    }

    /// Sessions this process started are never stale, only ones left behind by an earlier run.
    private func failStaleSessions() async throws {
        let launched = ProcessClock.launched.timeIntervalSince1970
        do {
            try await database.writer.write { db in
                try db.execute(
                    sql: """
                    UPDATE scan_session SET status = ?, finished_at = ?, error = ?
                    WHERE status = ? AND started_at < ?
                    """,
                    arguments: [
                        ScanStatus.failed, Date().timeIntervalSince1970, "The app quit before the scan finished",
                        ScanStatus.running, launched,
                    ],
                )
            }
        } catch {
            throw ScanPipelineError.persistence(error.localizedDescription)
        }
    }
}

struct PreparedScan: Sendable {
    let pipeline: ScanPipeline
    let options: ScanPipelineOptions
    let control: ScanControl
    let apps: [InstalledApp]
    let helperBundleIDs: Set<String>
    let allowlist: SystemAllowlist
    let engine: DefaultRuleEngine
    let rules: CompiledRuleSet

    var service: DefaultScanService {
        DefaultScanService(
            database: pipeline.database,
            walker: pipeline.walker,
            lastUsedResolver: pipeline.lastUsedResolver,
            progressInterval: pipeline.progressInterval,
            control: control,
            makeHandlers: makeHandlers,
        )
    }

    func makeHandlers(_ config: ScanConfig) -> [any ScanEntryHandler] {
        let home = pipeline.environment.homeURL
        let protection = pipeline.protection
        let gate = CandidateGate(policy: protection, excluded: config.candidateExcluded)
        let claims = WalkClaims()
        let exclusions = GraveyardCollector.defaultExclusions(home: home, quarantineFolder: pipeline.quarantineFolder)
        let collector = GraveyardCollector(
            searchRoots: options.projectRoots.isEmpty ? [home] : options.projectRoots,
            excluded: exclusions,
            scanner: pipeline.projectScanner,
        )
        let gitTrees = GitWorkTreeCache(home: home)
        var handlers: [any ScanEntryHandler] = [
            GraveyardScanHandler(collector: collector, gate: gate, claims: claims),
            RuleScanHandler(
                engine: engine,
                rules: rules,
                thresholds: options.thresholds,
                oldLarge: OldLargeRule(homeURL: home, isInsideGitWorkTree: gitTrees.contains),
                gate: gate,
                claims: claims,
            ),
        ]
        let library = home.appending(path: "Library", directoryHint: .isDirectory)
        if WalkRules.isInside(library.storagePath, anyOf: Set(config.roots.map(\.storagePath))) {
            handlers.append(OrphanScanHandler(
                library: library,
                apps: apps,
                helperBundleIDs: helperBundleIDs,
                allowlist: allowlist,
                policy: protection,
                applicationURL: pipeline.applicationURL,
                rules: rules,
                gate: gate,
            ))
        }
        handlers.append(DuplicateScanHandler(
            roots: options.duplicateRoots.isEmpty ? DuplicateOptions.defaultRoots(homeURL: home) : options.duplicateRoots,
            minSize: options.duplicateMinSize,
            homeURL: home,
            finder: pipeline.duplicateFinder,
            control: control,
            policy: protection,
            gate: gate,
            isInsideProject: collector.isInsideProject,
        ))
        return handlers
    }
}

struct PipelineScanService: ScanService {
    let pipeline: ScanPipeline
    let options: ScanPipelineOptions
    let control: ScanControl

    func scan(config: ScanConfig) -> AsyncThrowingStream<ScanEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ScanEvent.self, throwing: Error.self)
        control.attachCancel {}
        let task = Task { [pipeline, options, control] in
            defer { control.end() }
            do {
                let prepared = try await pipeline.prepare(options, control: control)
                guard !control.isCancelled else {
                    continuation.finish()
                    return
                }
                for try await event in prepared.service.scan(config: config) {
                    continuation.yield(event)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}
