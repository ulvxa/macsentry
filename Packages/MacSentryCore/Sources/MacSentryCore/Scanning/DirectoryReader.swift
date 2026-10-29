import Darwin
import Foundation

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
    let finderFlags: UInt16
    let error: UInt32

    var isDirectory: Bool {
        type == VDIR.rawValue
    }
}

enum DirectoryReadResult {
    case entries([RawEntry])
    case otherDevice
    case failed(errno: Int32)
}

final class DirectoryReader {
    static let bufferSize = 256 * 1024

    private static let commonAttributes = UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_NAME) | UInt32(ATTR_CMN_DEVID)
        | UInt32(ATTR_CMN_OBJTYPE) | UInt32(ATTR_CMN_CRTIME) | UInt32(ATTR_CMN_MODTIME) | UInt32(ATTR_CMN_FNDRINFO)
        | UInt32(ATTR_CMN_OWNERID) | UInt32(ATTR_CMN_FLAGS) | UInt32(ATTR_CMN_FILEID) | UInt32(ATTR_CMN_ERROR)
    private static let fileAttributes = UInt32(ATTR_FILE_LINKCOUNT) | UInt32(ATTR_FILE_ALLOCSIZE) | UInt32(ATTR_FILE_DATALENGTH)
    private static let extendedAttributes = UInt32(ATTR_CMNEXT_PRIVATESIZE)
    private static let options = UInt64(FSOPT_PACK_INVAL_ATTRS) | UInt64(FSOPT_ATTR_CMN_EXTENDED)

    private let buffer: UnsafeMutableRawPointer

    init() {
        buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 16)
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
        while true {
            let count = getattrlistbulk(descriptor, &request, buffer, Self.bufferSize, Self.options)
            if count == 0 {
                break
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                return entries.isEmpty ? .failed(errno: errno) : .entries(entries)
            }
            var cursor = UnsafeRawPointer(buffer)
            for _ in 0 ..< count {
                let length = cursor.loadUnaligned(as: UInt32.self)
                entries.append(Self.parse(cursor))
                cursor += Int(length)
            }
        }
        return .entries(entries)
    }

    private static func parse(_ start: UnsafeRawPointer) -> RawEntry {
        var cursor = start + MemoryLayout<UInt32>.size
        let returned = cursor.loadUnaligned(as: attribute_set_t.self)
        cursor += MemoryLayout<attribute_set_t>.size
        // getattrlistbulk packs ATTR_CMN_ERROR directly after the returned set, ahead of bit order.
        let error = take(UInt32.self, &cursor)

        let nameReference = cursor.loadUnaligned(as: attrreference_t.self)
        let name = String(cString: (cursor + Int(nameReference.attr_dataoffset)).assumingMemoryBound(to: UInt8.self))
        cursor += MemoryLayout<attrreference_t>.size

        let device = take(Int32.self, &cursor)
        let type = take(UInt32.self, &cursor)
        let created = take(timespec.self, &cursor)
        let modified = take(timespec.self, &cursor)
        let finderFlags = UInt16(bigEndian: (cursor + 8).loadUnaligned(as: UInt16.self))
        cursor += 32
        let owner = take(UInt32.self, &cursor)
        let flags = take(UInt32.self, &cursor)
        let inode = take(UInt64.self, &cursor)
        let linkCount = take(UInt32.self, &cursor)
        let allocated = take(Int64.self, &cursor)
        let logical = take(Int64.self, &cursor)
        let privateSize = take(Int64.self, &cursor)

        let hasPrivateSize = returned.forkattr & extendedAttributes != 0
        return RawEntry(
            name: name,
            type: type,
            device: device,
            inode: inode,
            linkCount: max(1, linkCount),
            logicalSize: logical,
            allocatedSize: allocated,
            privateSize: hasPrivateSize ? privateSize : nil,
            flags: flags,
            ownerUID: owner,
            created: date(created, valid: returned.commonattr & UInt32(ATTR_CMN_CRTIME) != 0),
            modified: date(modified, valid: returned.commonattr & UInt32(ATTR_CMN_MODTIME) != 0),
            finderFlags: finderFlags,
            error: returned.commonattr & UInt32(ATTR_CMN_ERROR) != 0 ? error : 0,
        )
    }

    private static func take<T>(_: T.Type, _ cursor: inout UnsafeRawPointer) -> T {
        let value = cursor.loadUnaligned(as: T.self)
        cursor += MemoryLayout<T>.size
        return value
    }

    private static func date(_ time: timespec, valid: Bool) -> Date? {
        guard valid else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000)
    }
}
