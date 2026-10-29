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
    public let environment: AppEnvironment
    public let database: Database
    public let protection: ProtectionPolicyProvider
    public let inventory: SystemAppInventory

    public init(
        environment: AppEnvironment,
        database: Database,
        protection: ProtectionPolicyProvider,
        inventory: SystemAppInventory,
    ) {
        self.environment = environment
        self.database = database
        self.protection = protection
        self.inventory = inventory
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

    public func makeService(options _: ScanPipelineOptions) -> any ScanService {
        DefaultScanService(database: database)
    }
}
