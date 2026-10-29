import Darwin
import Foundation
import Synchronization

struct RawEntry {
    let name: String
    let type: UInt32
    let device: Int32
    let inode: UInt64
    let linkCount: UInt32
    let logicalSize: Int64
    let allocatedSize: Int64
    let privateSize: Int64?
    let flags: UInt32
    let ownerUID: uid_t
    let created: Date?
    let modified: Date?
    let added: Date?
    let finderFlags: UInt16
    let error: UInt32

    var isDirectory: Bool {
        type == VDIR.rawValue
    }
}

enum DirectoryReadResult {
    case entries([RawEntry])
    case partial([RawEntry], errno: Int32)
    case otherDevice
    case failed(errno: Int32)
}

typealias BulkListing = @Sendable (Int32, UnsafeMutablePointer<attrlist>, UnsafeMutableRawPointer, Int, UInt64) -> Int32

/// One reader is checked out of ReaderPool by a single task at a time, so its buffer is never shared.
final class DirectoryReader: @unchecked Sendable {
    static let bufferSize = 256 * 1024

    private static let commonAttributes = UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_NAME) | UInt32(ATTR_CMN_DEVID)
        | UInt32(ATTR_CMN_OBJTYPE) | UInt32(ATTR_CMN_CRTIME) | UInt32(ATTR_CMN_MODTIME) | UInt32(ATTR_CMN_FNDRINFO)
        | UInt32(ATTR_CMN_OWNERID) | UInt32(ATTR_CMN_FLAGS) | UInt32(ATTR_CMN_FILEID) | UInt32(ATTR_CMN_ADDEDTIME)
        | UInt32(ATTR_CMN_ERROR)
    private static let fileAttributes = UInt32(ATTR_FILE_LINKCOUNT) | UInt32(ATTR_FILE_ALLOCSIZE) | UInt32(ATTR_FILE_DATALENGTH)
    private static let extendedAttributes = UInt32(ATTR_CMNEXT_PRIVATESIZE)
    private static let options = UInt64(FSOPT_PACK_INVAL_ATTRS) | UInt64(FSOPT_ATTR_CMN_EXTENDED)

    private let buffer: UnsafeMutableRawPointer
    private let bulk: BulkListing

    init(bulk: @escaping BulkListing = { getattrlistbulk($0, $1, $2, $3, $4) }) {
        buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 16)
        self.bulk = bulk
    }

    deinit {
        buffer.deallocate()
    }

    func read(_ path: String, allowedDevices: Set<Int32>) -> DirectoryReadResult {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return .failed(errno: errno) }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return .failed(errno: errno) }
        guard allowedDevices.contains(info.st_dev) else { return .otherDevice }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = Self.commonAttributes
        request.fileattr = Self.fileAttributes
        request.forkattr = Self.extendedAttributes

        var entries: [RawEntry] = []
        var malformed = false
        while true {
            let count = bulk(descriptor, &request, buffer, Self.bufferSize, Self.options)
            if count == 0 {
                break
            }
            if count < 0 {
                let code = errno
                if code == EINTR {
                    continue
                }
                return entries.isEmpty && !malformed ? .failed(errno: code) : .partial(entries, errno: code)
            }
            guard unpack(count, into: &entries, malformed: &malformed) else { return .partial(entries, errno: EIO) }
        }
        return malformed ? .partial(entries, errno: EIO) : .entries(entries)
    }

    private func unpack(_ count: Int32, into entries: inout [RawEntry], malformed: inout Bool) -> Bool {
        let end = UnsafeRawPointer(buffer) + Self.bufferSize
        var cursor = UnsafeRawPointer(buffer)
        for _ in 0 ..< count {
            let available = cursor.distance(to: end)
            guard available >= MemoryLayout<UInt32>.size else { return false }
            let length = Int(cursor.loadUnaligned(as: UInt32.self))
            guard length >= MemoryLayout<UInt32>.size, length <= available else { return false }
            if let entry = Self.parse(cursor, length: length) {
                entries.append(entry)
            } else {
                malformed = true
            }
            cursor += length
        }
        return true
    }

    static func parse(_ start: UnsafeRawPointer, length: Int) -> RawEntry? {
        var field = BoundedFields(start: start, length: length, offset: MemoryLayout<UInt32>.size)
        guard let returned = field.take(attribute_set_t.self) else { return nil }
        // getattrlistbulk packs ATTR_CMN_ERROR directly after the returned set, ahead of bit order.
        let packedError = field.take(UInt32.self) ?? 0
        let error = returned.commonattr & UInt32(ATTR_CMN_ERROR) != 0 ? packedError : 0
        let name = field.name()
        let device = field.take(Int32.self)
        let type = field.take(UInt32.self)
        let created = field.take(timespec.self)
        let modified = field.take(timespec.self)
        let finderFlags = field.finderFlags()
        let owner = field.take(UInt32.self)
        let flags = field.take(UInt32.self)
        let inode = field.take(UInt64.self)
        let added = field.take(timespec.self)
        let linkCount = field.take(UInt32.self)
        let allocated = field.take(Int64.self)
        let logical = field.take(Int64.self)
        let privateSize = field.take(Int64.self)
        guard error != 0 || (name?.isEmpty == false && type != nil) else { return nil }

        let hasPrivateSize = returned.forkattr & extendedAttributes != 0 && privateSize != nil
        return RawEntry(
            name: name ?? "",
            type: type ?? 0,
            device: device ?? 0,
            inode: inode ?? 0,
            linkCount: max(1, linkCount ?? 1),
            logicalSize: logical ?? 0,
            allocatedSize: allocated ?? 0,
            privateSize: hasPrivateSize ? privateSize : nil,
            flags: flags ?? 0,
            ownerUID: owner ?? 0,
            created: created.flatMap { date($0, valid: returned.commonattr & UInt32(ATTR_CMN_CRTIME) != 0) },
            modified: modified.flatMap { date($0, valid: returned.commonattr & UInt32(ATTR_CMN_MODTIME) != 0) },
            added: added.flatMap { date($0, valid: returned.commonattr & UInt32(ATTR_CMN_ADDEDTIME) != 0) },
            finderFlags: finderFlags ?? 0,
            error: error,
        )
    }

    private static func date(_ time: timespec, valid: Bool) -> Date? {
        guard valid else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000)
    }
}

private struct BoundedFields {
    let start: UnsafeRawPointer
    let length: Int
    var offset: Int

    mutating func take<T: BitwiseCopyable>(_: T.Type) -> T? {
        let size = MemoryLayout<T>.size
        guard offset + size <= length else { return nil }
        defer { offset += size }
        return (start + offset).loadUnaligned(as: T.self)
    }

    mutating func name() -> String? {
        let referenceOffset = offset
        guard let reference = take(attrreference_t.self) else { return nil }
        let begin = referenceOffset + Int(reference.attr_dataoffset)
        guard begin >= 0, begin < length, reference.attr_length > 0 else { return nil }
        let bytes = UnsafeRawBufferPointer(start: start + begin, count: min(Int(reference.attr_length), length - begin))
        return String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8)
    }

    mutating func finderFlags() -> UInt16? {
        let size = 32
        guard offset + size <= length else { return nil }
        defer { offset += size }
        return UInt16(bigEndian: (start + offset + 8).loadUnaligned(as: UInt16.self))
    }
}

final class ReaderPool: Sendable {
    private let state = Mutex<(idle: [DirectoryReader], created: Int)>(([], 0))
    private let makeReader: @Sendable () -> DirectoryReader

    init(makeReader: @escaping @Sendable () -> DirectoryReader = { DirectoryReader() }) {
        self.makeReader = makeReader
    }

    var created: Int {
        state.withLock(\.created)
    }

    func checkout() -> DirectoryReader {
        if let reader = state.withLock({ $0.idle.popLast() }) {
            return reader
        }
        state.withLock { $0.created += 1 }
        return makeReader()
    }

    func checkin(_ reader: DirectoryReader) {
        state.withLock { $0.idle.append(reader) }
    }
}
