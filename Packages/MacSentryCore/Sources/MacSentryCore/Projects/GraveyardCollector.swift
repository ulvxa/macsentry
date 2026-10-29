import Foundation
import Synchronization

public struct GraveyardProject: Sendable, Equatable {
    public var project: Project
    public var artifacts: [Candidate]
    public var hasGit: Bool
    public var uncommitted: UncommittedState
    public var gitUnavailable: Bool

    public init(project: Project, artifacts: [Candidate], hasGit: Bool, uncommitted: UncommittedState, gitUnavailable: Bool) {
        self.project = project
        self.artifacts = artifacts
        self.hasGit = hasGit
        self.uncommitted = uncommitted
        self.gitUnavailable = gitUnavailable
    }
}

public final class GraveyardCollector: Sendable {
    public static let finishConcurrency = 4

    public let searchRoots: [URL]
    public let excluded: [URL]
    private let scanner: any ProjectScanner
    private let probe: any ProjectFileProbe
    private let artifactNames: Set<String>
    private let rootPaths: [String]
    private let excludedPaths: [String]
    private let state = Mutex(State())

    public init(
        searchRoots: [URL],
        excluded: [URL],
        scanner: any ProjectScanner = DefaultProjectScanner(),
        probe: any ProjectFileProbe = FileManagerProjectProbe(),
    ) {
        self.searchRoots = searchRoots
        self.excluded = excluded
        self.scanner = scanner
        self.probe = probe
        artifactNames = scanner.artifactFolderNames
        rootPaths = searchRoots.map(\.storagePath)
        excludedPaths = excluded.map(\.storagePath)
    }

    public convenience init(
        home: URL,
        quarantineFolder: URL?,
        scanner: any ProjectScanner = DefaultProjectScanner(),
        probe: any ProjectFileProbe = FileManagerProjectProbe(),
    ) {
        self.init(
            searchRoots: [home],
            excluded: Self.defaultExclusions(home: home, quarantineFolder: quarantineFolder),
            scanner: scanner,
            probe: probe,
        )
    }

    public static func defaultExclusions(home: URL, quarantineFolder: URL?) -> [URL] {
        [home.appending(path: "Library", directoryHint: .isDirectory), home.appending(path: ".Trash", directoryHint: .isDirectory)]
            + (quarantineFolder.map { [$0] } ?? [])
    }

    public func visit(_ entry: FileEntry) -> WalkDecision {
        let path = entry.url.storagePath
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex || path.count > 1 else { return .descend }
        let parentPath = slash == path.startIndex ? "/" : String(path[..<slash])
        let name = String(path[path.index(after: slash)...])
        let context = state.withLock { resolveContext(forParent: parentPath, in: &$0) }

        guard context.inScope, !context.insideGit, name != ".git" else { return .descend }
        if context.insideArtifact {
            return .skipChildren
        }
        if context.atSearchRoot, name.hasPrefix(".") {
            return .descend
        }

        switch entry.kind {
        case .file, .package:
            if let owner = context.owner, name != ".DS_Store", let modified = entry.modified {
                state.withLock { $0.projects[owner]?.noteModified(modified) }
            }
            return .descend
        case .symlink:
            return .descend
        case .folder:
            return visitFolder(entry, path: path, parentPath: parentPath, name: name, context: context)
        }
    }

    public func finish(
        sessionID: Int64,
        sizeOf: @escaping @Sendable (URL) async throws -> SizeInfo,
    ) async -> [GraveyardProject] {
        let accumulators = state.withLock { $0.projects.values.filter { !$0.artifacts.isEmpty } }
        let scanner = scanner
        let results = await accumulators.concurrentMap(limit: Self.finishConcurrency) { accumulator in
            await Self.build(accumulator, sessionID: sessionID, scanner: scanner, sizeOf: sizeOf)
        }
        return results.compactMap(\.self).sorted {
            ($0.project.artifactsSize, $1.project.rootURL.storagePath) > ($1.project.artifactsSize, $0.project.rootURL.storagePath)
        }
    }

    private func visitFolder(_ entry: FileEntry, path: String, parentPath: String, name: String, context: Context) -> WalkDecision {
        if excludedPaths.contains(path) {
            return .descend
        }
        if let owner = context.owner, artifactNames.contains(name) {
            let siblings = state.withLock { $0.siblings[parentPath] } ?? probe.contents(of: URL(filePath: parentPath))
            if let match = scanner.artifact(for: entry.url, name: name, siblings: siblings),
               !probe.itemExists(at: entry.url.appending(path: ".git")) {
                state.withLock { state in
                    state.artifactPaths.insert(path)
                    state.projects[owner]?.add(ArtifactRecord(match: match, created: entry.created, modified: entry.modified))
                }
                return .skipChildren
            }
        }

        let entries = probe.contents(of: entry.url)
        let marker = scanner.isProjectRoot(entry.url, entries: entries)
            ?? (context.owner == nil ? implicitMarker(for: entry.url, entries: entries) : nil)
        let keepsSiblings = entries.contains { artifactNames.contains($0) }
        guard marker != nil || keepsSiblings else { return .descend }
        state.withLock { state in
            if keepsSiblings {
                state.siblings[path] = entries
            }
            if let marker {
                register(entry, path: path, marker: marker, context: context, in: &state)
            }
        }
        return .descend
    }

    private func implicitMarker(for dir: URL, entries: [String]) -> ProjectMarker? {
        let ecosystems = entries.filter(artifactNames.contains).compactMap { child -> Ecosystem? in
            let url = dir.appending(path: child, directoryHint: .isDirectory)
            guard probe.isDirectory(at: url),
                  let match = scanner.artifact(for: url, name: child, siblings: entries),
                  match.rule.requiresMarker, match.markerRoot.storagePath == dir.storagePath
            else { return nil }
            return match.rule.ecosystem
        }
        return ecosystems.isEmpty ? nil : ProjectMarker(hasGit: false, ecosystems: Set(ecosystems))
    }

    private func register(_ entry: FileEntry, path: String, marker: ProjectMarker, context: Context, in state: inout State) {
        let owner: String = if let candidate = context.owner, let existing = state.projects[candidate],
                               existing.hasGit || !marker.hasGit {
            candidate
        } else {
            path
        }
        state.roots[path] = owner
        if owner == path {
            state.projects[path] = ProjectAccumulator(root: entry.url, hasGit: marker.hasGit, rootModified: entry.modified)
        }
        state.projects[owner]?.ecosystems.formUnion(marker.ecosystems)
        state.cached = nil
    }

    private func resolveContext(forParent parentPath: String, in state: inout State) -> Context {
        if let cached = state.cached, cached.parent == parentPath {
            return cached.context
        }
        let context = computeContext(forParent: parentPath, state: state)
        state.cached = (parentPath, context)
        return context
    }

    private func computeContext(forParent parentPath: String, state: State) -> Context {
        guard let rootPath = rootPaths.filter({ parentPath == $0 || parentPath.hasPrefix($0 == "/" ? "/" : $0 + "/") })
            .max(by: { $0.count < $1.count }),
            !excludedPaths.contains(where: { parentPath == $0 || parentPath.hasPrefix($0 + "/") })
        else { return Context(inScope: false) }

        if parentPath == rootPath {
            return Context(inScope: true, atSearchRoot: true)
        }
        let relative = parentPath.dropFirst(rootPath == "/" ? 1 : rootPath.count + 1)
        if relative.hasPrefix(".") {
            return Context(inScope: false)
        }

        var context = Context(inScope: true)
        var cursor = Substring(parentPath)
        while cursor.count > rootPath.count {
            let current = String(cursor)
            guard let slash = cursor.lastIndex(of: "/") else { break }
            if cursor[cursor.index(after: slash)...] == ".git" {
                context.insideGit = true
            }
            if state.artifactPaths.contains(current) {
                context.insideArtifact = true
            }
            if context.owner == nil, let owner = state.roots[current] {
                context.owner = owner
                break
            }
            cursor = cursor[..<slash]
        }
        return context
    }

    private static func build(
        _ accumulator: ProjectAccumulator,
        sessionID: Int64,
        scanner: any ProjectScanner,
        sizeOf: @Sendable (URL) async throws -> SizeInfo,
    ) async -> GraveyardProject? {
        let name = accumulator.root.lastPathComponent
        var candidates: [Candidate] = []
        for record in accumulator.artifacts.sorted(by: { $0.match.url.storagePath < $1.match.url.storagePath }) {
            guard let size = try? await sizeOf(record.match.url) else { continue }
            let rule = record.match.rule
            candidates.append(Candidate(
                sessionID: sessionID,
                url: record.match.url,
                kind: .folder,
                category: .projectArtifact,
                ruleID: rule.ruleID,
                tier: rule.tier,
                action: .quarantine,
                reason: "`\(rule.folder)` of \(name). \(rule.ecosystem.regenerationHint)",
                logicalSize: size.logical,
                allocatedSize: size.allocated,
                freeableSize: size.freeable,
                createdAt: record.created,
                modifiedAt: record.modified,
            ))
        }
        guard !candidates.isEmpty else { return nil }

        let info = accumulator.hasGit ? await scanner.gitInfo(forRepositoryAt: accumulator.root) : nil
        let project = Project(
            sessionID: sessionID,
            rootURL: accumulator.root,
            name: name,
            ecosystems: accumulator.ecosystems.sorted().map(\.rawValue),
            lastCommitAt: info?.lastCommitAt,
            lastModifiedAt: accumulator.lastModified ?? accumulator.rootModified ?? Date(timeIntervalSince1970: 0),
            hasUncommitted: info?.storedHasUncommitted ?? false,
            artifactsSize: candidates.reduce(0) { $0 + $1.freeableSize },
        )
        return GraveyardProject(
            project: project,
            artifacts: candidates,
            hasGit: accumulator.hasGit,
            uncommitted: info?.uncommitted ?? .clean,
            gitUnavailable: info?.gitUnavailable ?? false,
        )
    }
}

private struct Context {
    var inScope: Bool
    var atSearchRoot = false
    var insideGit = false
    var insideArtifact = false
    var owner: String?
}

private struct ArtifactRecord {
    let match: ArtifactMatch
    let created: Date?
    let modified: Date?
}

private struct ProjectAccumulator {
    let root: URL
    let hasGit: Bool
    let rootModified: Date?
    var ecosystems: Set<Ecosystem> = []
    var lastModified: Date?
    var artifacts: [ArtifactRecord] = []

    mutating func noteModified(_ date: Date) {
        lastModified = max(lastModified ?? date, date)
    }

    mutating func add(_ artifact: ArtifactRecord) {
        artifacts.append(artifact)
        ecosystems.insert(artifact.match.rule.ecosystem)
    }
}

private struct State {
    var roots: [String: String] = [:]
    var projects: [String: ProjectAccumulator] = [:]
    var artifactPaths: Set<String> = []
    var siblings: [String: [String]] = [:]
    var cached: (parent: String, context: Context)?
}
