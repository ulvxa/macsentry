import Darwin
import Foundation

public struct FixtureBuilder: Sendable {
    public let root: URL

    public init(name: String = "Fixture") throws {
        FixtureSweeper.sweepOnce
        let base = FileManager.default.temporaryDirectory
            .appending(path: "MacSentryFixtures", directoryHint: .isDirectory)
            .appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try Self.fileSystem("createDirectory", base) {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        }
        root = base.resolvingSymlinksInPath()
    }

    public func url(_ relativePath: String) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard !relativePath.hasPrefix("/"), !components.isEmpty,
              !components.contains(where: { $0 == ".." || $0 == "." })
        else {
            throw FixtureError.invalidRelativePath(relativePath)
        }
        return root.appending(path: relativePath)
    }

    @discardableResult
    public func folder(_ relativePath: String, created: Date? = nil, modified: Date? = nil, added: Date? = nil) throws -> URL {
        let target = try url(relativePath)
        try Self.fileSystem("createDirectory", target) {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        }
        try setDates(of: target, created: created, modified: modified, added: added)
        return target
    }

    @discardableResult
    public func file(
        _ relativePath: String,
        size: Int64 = 0,
        fill: UInt8 = 0x61,
        created: Date? = nil,
        modified: Date? = nil,
        added: Date? = nil,
    ) throws -> URL {
        let target = try prepareParent(relativePath)
        let descriptor = try Self.openForWriting(target)
        defer { close(descriptor) }
        let chunk = [UInt8](repeating: fill, count: Int(min(size, 1 << 20)))
        var remaining = size
        while remaining > 0 {
            let count = Int(min(remaining, Int64(chunk.count)))
            let written = chunk.withUnsafeBytes { write(descriptor, $0.baseAddress, count) }
            guard written == count else {
                throw FixtureError.systemCall("write", path: target.path(percentEncoded: false), errno: errno)
            }
            remaining -= Int64(count)
        }
        try setDates(of: target, created: created, modified: modified, added: added)
        return target
    }

    @discardableResult
    public func sparseFile(
        _ relativePath: String,
        logicalSize: Int64,
        created: Date? = nil,
        modified: Date? = nil,
        added: Date? = nil,
    ) throws -> URL {
        let target = try prepareParent(relativePath)
        let descriptor = try Self.openForWriting(target)
        defer { close(descriptor) }
        guard ftruncate(descriptor, off_t(logicalSize)) == 0 else {
            throw FixtureError.systemCall("ftruncate", path: target.path(percentEncoded: false), errno: errno)
        }
        try setDates(of: target, created: created, modified: modified, added: added)
        return target
    }

    @discardableResult
    public func symlink(_ relativePath: String, to destination: URL) throws -> URL {
        let target = try prepareParent(relativePath)
        try Self.fileSystem("createSymbolicLink", target) {
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: destination)
        }
        return target
    }

    @discardableResult
    public func hardLink(_ relativePath: String, to existing: URL) throws -> URL {
        let target = try prepareParent(relativePath)
        guard link(existing.path(percentEncoded: false), target.path(percentEncoded: false)) == 0 else {
            throw FixtureError.systemCall("link", path: target.path(percentEncoded: false), errno: errno)
        }
        return target
    }

    @discardableResult
    public func clone(_ relativePath: String, of source: URL) throws -> URL {
        let target = try prepareParent(relativePath)
        guard clonefile(source.path(percentEncoded: false), target.path(percentEncoded: false), 0) == 0 else {
            throw FixtureError.systemCall("clonefile", path: target.path(percentEncoded: false), errno: errno)
        }
        return target
    }

    /// Backdating a file also backdates its date added unless `added` says otherwise, so fixtures read as old on every axis.
    public func setDates(of target: URL, created: Date? = nil, modified: Date? = nil, added: Date? = nil) throws {
        var attributes: [FileAttributeKey: Any] = [:]
        if let created {
            attributes[.creationDate] = created
        }
        if let modified {
            attributes[.modificationDate] = modified
        }
        guard !attributes.isEmpty else { return }
        try Self.fileSystem("setAttributes", target) {
            try FileManager.default.setAttributes(attributes, ofItemAtPath: target.path(percentEncoded: false))
        }
        if let addedDate = added ?? [created, modified].compactMap(\.self).min() {
            try setAddedDate(of: target, to: addedDate)
        }
    }

    private func setAddedDate(of target: URL, to date: Date) throws {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_ADDEDTIME)
        let seconds = date.timeIntervalSince1970
        var time = timespec(tv_sec: Int(seconds.rounded(.down)), tv_nsec: 0)
        let path = target.path(percentEncoded: false)
        guard setattrlist(path, &list, &time, MemoryLayout<timespec>.size, 0) == 0 else {
            throw FixtureError.systemCall("setattrlist", path: path, errno: errno)
        }
    }

    private func prepareParent(_ relativePath: String) throws -> URL {
        let target = try url(relativePath)
        let parent = target.deletingLastPathComponent()
        try Self.fileSystem("createDirectory", parent) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        return target
    }

    private static func openForWriting(_ target: URL) throws -> Int32 {
        let descriptor = open(target.path(percentEncoded: false), O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard descriptor >= 0 else {
            throw FixtureError.systemCall("open", path: target.path(percentEncoded: false), errno: errno)
        }
        return descriptor
    }

    private static func fileSystem(_ operation: String, _ target: URL, _ body: () throws -> Void) throws {
        do {
            try body()
        } catch {
            throw FixtureError.fileSystem(operation, path: target.path(percentEncoded: false), reason: error.localizedDescription)
        }
    }
}
