import Foundation
import GRDB
import Synchronization

struct TreeRow: Equatable {
    let path: String
    let parentPath: String?
    let depth: Int
    let allocatedSize: Int64
    let fileCount: Int64
}

final class DirectoryTree: Sendable {
    private struct Totals {
        var bytes: Int64 = 0
        var files: Int64 = 0
    }

    private struct State {
        var nodes: [String: Totals]
        var seenLinks: Set<InodeKey> = []
    }

    let rootPath: String
    private let prefixLength: Int
    private let maxDepth: Int
    private let state: Mutex<State>

    init(root: URL, maxDepth: Int) {
        rootPath = WalkRules.path(of: root)
        prefixLength = rootPath == "/" ? 1 : rootPath.utf8.count + 1
        self.maxDepth = maxDepth
        state = Mutex(State(nodes: [rootPath: Totals()]))
    }

    func addFolder(_ url: URL) {
        let path = WalkRules.path(of: url)
        guard depth(of: path) <= maxDepth else { return }
        state.withLock { state in
            if state.nodes[path] == nil {
                state.nodes[path] = Totals()
            }
        }
    }

    func addItem(_ entry: FileEntry) {
        let path = WalkRules.path(of: entry.url)
        if entry.kind == .package {
            addAggregate(path: path, allocated: entry.allocatedSize, files: 1)
            return
        }
        let owner = ancestor(of: path, atDepth: min(depth(of: path) - 1, maxDepth))
        let key = InodeKey(device: entry.device, inode: entry.inode)
        let countsBytes = entry.kind != .file || entry.linkCount <= 1
        state.withLock { state in
            let bytes = countsBytes || state.seenLinks.insert(key).inserted ? entry.allocatedSize : 0
            state.nodes[owner, default: Totals()].bytes += bytes
            state.nodes[owner, default: Totals()].files += 1
        }
    }

    func addAggregate(path: String, allocated: Int64, files: Int) {
        let depth = depth(of: path)
        let owner = depth <= maxDepth ? path : ancestor(of: path, atDepth: maxDepth)
        state.withLock { state in
            state.nodes[owner, default: Totals()].bytes += allocated
            state.nodes[owner, default: Totals()].files += Int64(files)
        }
    }

    func rows(minNodeSize: Int64, alwaysKeepDepth: Int = 3) -> [TreeRow] {
        var totals = state.withLock { $0.nodes }
        for path in Array(totals.keys) {
            var current = path
            var level = depth(of: current)
            while level > 0 {
                current = ancestor(of: current, atDepth: level - 1)
                level -= 1
                guard totals[current] == nil else { break }
                totals[current] = Totals()
            }
        }
        let byDepth = totals.keys.map { ($0, depth(of: $0)) }.sorted { $0.1 > $1.1 }
        for (path, level) in byDepth where level > 0 {
            guard let own = totals[path] else { continue }
            let parent = ancestor(of: path, atDepth: level - 1)
            totals[parent, default: Totals()].bytes += own.bytes
            totals[parent, default: Totals()].files += own.files
        }
        return byDepth.reversed().compactMap { path, level in
            guard let total = totals[path], level <= alwaysKeepDepth || total.bytes >= minNodeSize else { return nil }
            return TreeRow(
                path: path,
                parentPath: level == 0 ? nil : ancestor(of: path, atDepth: level - 1),
                depth: level,
                allocatedSize: total.bytes,
                fileCount: total.files,
            )
        }
    }

    func depth(of path: String) -> Int {
        guard path != rootPath else { return 0 }
        return 1 + path.utf8.dropFirst(prefixLength).count { $0 == UInt8(ascii: "/") }
    }

    func ancestor(of path: String, atDepth target: Int) -> String {
        guard target > 0 else { return rootPath }
        let utf8 = path.utf8
        var index = utf8.index(utf8.startIndex, offsetBy: prefixLength, limitedBy: utf8.endIndex) ?? utf8.endIndex
        var slashes = 0
        while index < utf8.endIndex {
            if utf8[index] == UInt8(ascii: "/") {
                slashes += 1
                if slashes == target {
                    return String(path[..<index])
                }
            }
            index = utf8.index(after: index)
        }
        return path
    }

    static func write(_ rows: [TreeRow], sessionID: Int64, database: Database, batchSize: Int) async throws {
        var ids: [String: Int64] = [:]
        var start = rows.startIndex
        while start < rows.endIndex {
            let end = min(start + batchSize, rows.endIndex)
            let batch = Array(rows[start ..< end])
            let known = ids
            let inserted = try await database.writer.write { db in
                var batchIDs: [String: Int64] = [:]
                for row in batch {
                    var node = DirNode(
                        sessionID: sessionID,
                        parentID: row.parentPath.flatMap { batchIDs[$0] ?? known[$0] },
                        url: URL(filePath: row.path, directoryHint: .isDirectory),
                        name: row.depth == 0 ? URL(filePath: row.path)
                            .lastPathComponent : String(row.path.split(separator: "/").last ?? ""),
                        depth: row.depth,
                        allocatedSize: row.allocatedSize,
                        fileCount: row.fileCount,
                    )
                    try node.insert(db)
                    batchIDs[row.path] = node.id
                }
                return batchIDs
            }
            ids.merge(inserted) { $1 }
            start = end
        }
    }
}
