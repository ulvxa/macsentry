import CryptoKit
import Darwin
import Foundation

enum HashOutcome: Sendable, Equatable {
    case digest(String)
    case unreadable
    case changed
    case dataless
}

enum FileHasher {
    static let edgeLength: Int64 = 64 * 1024
    static let chunkLength = 1 << 20
    static let modifiedTolerance: TimeInterval = 0.001

    static func verify(_ entry: FileEntry) -> HashOutcome? {
        switch FileProbe.status(of: entry.url) {
        case .failure(.unreadable(_, errno: ENOENT)):
            return .changed
        case .failure:
            return .unreadable
        case let .success(status):
            if status.isDataless {
                return .dataless
            }
            guard status.kind == .file, status.size == entry.logicalSize,
                  status.inode == entry.inode, status.device == entry.device
            else { return .changed }
            if let modified = entry.modified, abs(status.modified.timeIntervalSince(modified)) > modifiedTolerance {
                return .changed
            }
            return nil
        }
    }

    static func partialHash(_ entry: FileEntry) -> HashOutcome {
        if let rejected = verify(entry) {
            return rejected
        }
        guard let handle = try? FileHandle(forReadingFrom: entry.url) else { return .unreadable }
        defer { try? handle.close() }
        let length = min(edgeLength, entry.logicalSize)
        do {
            let head = try handle.read(upToCount: Int(length)) ?? Data()
            try handle.seek(toOffset: UInt64(entry.logicalSize - length))
            let tail = try handle.read(upToCount: Int(length)) ?? Data()
            guard head.count == length, tail.count == length else { return .changed }
            var hasher = SHA256()
            hasher.update(data: head)
            hasher.update(data: tail)
            withUnsafeBytes(of: entry.logicalSize.littleEndian) { hasher.update(bufferPointer: $0) }
            return .digest(hex(hasher.finalize()))
        } catch {
            return .unreadable
        }
    }

    static func fullHash(_ entry: FileEntry, onBytes: (Int) -> Void) throws(CancellationError) -> HashOutcome {
        if let rejected = verify(entry) {
            return rejected
        }
        guard let handle = try? FileHandle(forReadingFrom: entry.url) else { return .unreadable }
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            if Task.isCancelled {
                throw CancellationError()
            }
            let chunk: Data
            do {
                guard let data = try handle.read(upToCount: chunkLength), !data.isEmpty else { break }
                chunk = data
            } catch {
                return .unreadable
            }
            hasher.update(data: chunk)
            total += Int64(chunk.count)
            onBytes(chunk.count)
        }
        guard total == entry.logicalSize, verify(entry) == nil else { return .changed }
        return .digest(hex(hasher.finalize()))
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
