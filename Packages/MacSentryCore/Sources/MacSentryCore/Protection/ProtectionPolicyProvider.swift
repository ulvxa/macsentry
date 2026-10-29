import Foundation
import Synchronization

public final class ProtectionPolicyProvider: ProtectionPolicy {
    private struct State {
        var policy: DefaultProtectionPolicy
        var generation = 0
        var isKnownArtifact: ArtifactPredicate
    }

    private let homeURL: URL
    private let databaseURL: URL
    private let neverTouchStore: any NeverTouchStore
    private let ignoredPathStore: any IgnoredPathStore
    private let appInventory: (any AppInventory)?
    private let state: Mutex<State>

    public init(
        homeURL: URL,
        databaseURL: URL,
        neverTouchStore: any NeverTouchStore,
        ignoredPathStore: any IgnoredPathStore,
        appInventory: (any AppInventory)? = nil,
        isKnownArtifact: @escaping ArtifactPredicate = DefaultProtectionPolicy.isDefaultArtifact,
    ) {
        self.homeURL = homeURL
        self.databaseURL = databaseURL
        self.neverTouchStore = neverTouchStore
        self.ignoredPathStore = ignoredPathStore
        self.appInventory = appInventory
        state = Mutex(State(
            policy: DefaultProtectionPolicy(homeURL: homeURL, databaseURL: databaseURL, isKnownArtifact: isKnownArtifact),
            isKnownArtifact: isKnownArtifact,
        ))
    }

    public convenience init(
        environment: AppEnvironment,
        neverTouchStore: any NeverTouchStore,
        ignoredPathStore: any IgnoredPathStore,
        appInventory: (any AppInventory)? = nil,
        isKnownArtifact: @escaping ArtifactPredicate = DefaultProtectionPolicy.isDefaultArtifact,
    ) {
        self.init(
            homeURL: environment.homeURL,
            databaseURL: environment.databaseURL,
            neverTouchStore: neverTouchStore,
            ignoredPathStore: ignoredPathStore,
            appInventory: appInventory,
            isKnownArtifact: isKnownArtifact,
        )
    }

    public var current: DefaultProtectionPolicy {
        state.withLock(\.policy)
    }

    public func check(_ url: URL) -> ProtectionVerdict {
        current.check(url)
    }

    public func setKnownArtifact(_ predicate: @escaping ArtifactPredicate) {
        state.withLock { $0.isKnownArtifact = predicate }
    }

    public func refresh() async throws {
        let (generation, isKnownArtifact) = state.withLock { state in
            state.generation += 1
            return (state.generation, state.isKnownArtifact)
        }
        let patterns = try await neverTouchStore.patterns().map(\.pattern)
        let ignored = try await ignoredPathStore.paths().map(\.url)
        let bundleIDs = await Set(appInventory?.installedApps().map(\.bundleID) ?? [])
        let policy = DefaultProtectionPolicy(
            homeURL: homeURL,
            databaseURL: databaseURL,
            installedBundleIDs: bundleIDs,
            neverTouchPatterns: patterns,
            ignoredPaths: ignored,
            isKnownArtifact: isKnownArtifact,
        )
        state.withLock { state in
            if state.generation == generation {
                state.policy = policy
            }
        }
    }
}
