import Foundation
import Synchronization

public final class ProtectionPolicyProvider: ProtectionPolicy {
    public static let loadingReason = "Protection rules are still loading"

    private struct State {
        var policy: DefaultProtectionPolicy
        var isKnownArtifact: ArtifactPredicate
        var isReady = false
        var started = 0
        var applied = 0
        var lastError: String?
        var failed = 0
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

    public var isReady: Bool {
        state.withLock(\.isReady)
    }

    public var lastRefreshError: String? {
        state.withLock(\.lastError)
    }

    public func check(_ url: URL) -> ProtectionVerdict {
        let (ready, policy) = state.withLock { ($0.isReady, $0.policy) }
        return ready ? policy.check(url) : .denied(Self.loadingReason)
    }

    public func setKnownArtifact(_ predicate: @escaping ArtifactPredicate) {
        state.withLock { $0.isKnownArtifact = predicate }
    }

    public func refresh() async throws {
        let (generation, isKnownArtifact) = state.withLock { state in
            state.started += 1
            return (state.started, state.isKnownArtifact)
        }
        let policy: DefaultProtectionPolicy
        do {
            let patterns = try await neverTouchStore.patterns().map(\.pattern)
            let ignored = try await ignoredPathStore.paths().map(\.url)
            let bundleIDs = await Set(appInventory?.installedApps().map(\.bundleID) ?? [])
            policy = DefaultProtectionPolicy(
                homeURL: homeURL,
                databaseURL: databaseURL,
                installedBundleIDs: bundleIDs,
                neverTouchPatterns: patterns,
                ignoredPaths: ignored,
                isKnownArtifact: isKnownArtifact,
            )
        } catch {
            state.withLock { state in
                if generation > state.applied, generation > state.failed {
                    state.failed = generation
                    state.lastError = error.localizedDescription
                }
            }
            throw error
        }
        state.withLock { state in
            guard generation > state.applied else { return }
            state.applied = generation
            state.policy = policy
            state.isReady = true
            if generation > state.failed {
                state.lastError = nil
            }
        }
    }
}
