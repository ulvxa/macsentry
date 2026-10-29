import Darwin
import Foundation

enum FileProbe {
    struct Status: Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let allocated: Int64
        let flags: UInt32
        let linkCount: UInt32
        let ownerUID: uid_t
        let kind: EntryKind
        let created: Date
        let modified: Date

        var isDataless: Bool {
            flags & UInt32(SF_DATALESS) != 0
        }
    }

    static func status(of url: URL) -> Result<Status, DuplicateError> {
        var info = Darwin.stat()
        guard lstat(url.path(percentEncoded: false), &info) == 0 else {
            return .failure(.unreadable(url, errno: errno))
        }
        return .success(Status(
            device: info.st_dev,
            inode: info.st_ino,
            size: info.st_size,
            allocated: info.st_blocks * 512,
            flags: info.st_flags,
            linkCount: UInt32(info.st_nlink),
            ownerUID: info.st_uid,
            kind: kind(info.st_mode),
            created: date(info.st_birthtimespec),
            modified: date(info.st_mtimespec),
        ))
    }

    static func privateSize(of url: URL) -> Int64? {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        list.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        var buffer = [UInt8](repeating: 0, count: 64)
        let result = buffer.withUnsafeMutableBytes { raw in
            getattrlist(
                url.path(percentEncoded: false), &list, raw.baseAddress, raw.count,
                UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW),
            )
        }
        guard result == 0 else { return nil }
        return buffer.withUnsafeBytes { raw in
            let returned = raw.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self)
            guard returned.forkattr & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0 else { return nil }
            return raw.loadUnaligned(fromByteOffset: 4 + MemoryLayout<attribute_set_t>.size, as: off_t.self)
        }
    }

    static func entry(for url: URL) throws(DuplicateError) -> FileEntry {
        let status = try status(of: url).get()
        return FileEntry(
            url: url,
            kind: status.kind,
            logicalSize: status.size,
            allocatedSize: status.allocated,
            privateSize: privateSize(of: url),
            linkCount: status.linkCount,
            inode: status.inode,
            device: status.device,
            flags: status.flags,
            created: status.created,
            modified: status.modified,
            ownerUID: status.ownerUID,
        )
    }

    private static func kind(_ mode: mode_t) -> EntryKind {
        switch mode & S_IFMT {
        case S_IFDIR: .folder
        case S_IFLNK: .symlink
        default: .file
        }
    }

    private static func date(_ spec: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(spec.tv_sec) + TimeInterval(spec.tv_nsec) / 1_000_000_000)
    }
}
