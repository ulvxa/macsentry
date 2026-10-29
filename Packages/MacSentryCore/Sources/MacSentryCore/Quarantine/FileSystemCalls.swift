import Darwin
import Foundation

struct POSIXFailure: Error, Equatable {
    let code: Int32
}

struct FileStatus {
    let mode: mode_t
    let flags: UInt32
    let blocks: Int64

    var isSymlink: Bool {
        mode & S_IFMT == S_IFLNK
    }

    var isDirectory: Bool {
        mode & S_IFMT == S_IFDIR
    }

    var allocatedBytes: Int64 {
        blocks * 512
    }

    var isLocked: Bool {
        flags & (UInt32(UF_IMMUTABLE) | UInt32(SF_IMMUTABLE)) != 0
    }

    var isDataless: Bool {
        flags & UInt32(SF_DATALESS) != 0
    }
}

enum FileSystemCalls {
    static func status(of url: URL) throws(POSIXFailure) -> FileStatus {
        var info = stat()
        let code = withPath(url) { lstat($0, &info) == 0 ? 0 : errno }
        guard code == 0 else { throw POSIXFailure(code: code) }
        return FileStatus(mode: info.st_mode, flags: info.st_flags, blocks: Int64(info.st_blocks))
    }

    static func exists(_ url: URL) -> Bool {
        (try? status(of: url)) != nil
    }

    static func renameExclusive(_ source: URL, to destination: URL) throws(POSIXFailure) {
        let code = withPath(source) { sourcePath in
            withPath(destination) { renamex_np(sourcePath, $0, UInt32(RENAME_EXCL)) == 0 ? 0 : errno }
        }
        guard code == 0 else { throw POSIXFailure(code: code) }
    }

    static func makeDirectory(_ url: URL) throws(POSIXFailure) {
        let code = withPath(url) { mkdir($0, 0o755) == 0 ? 0 : errno }
        guard code == 0 else { throw POSIXFailure(code: code) }
    }

    @discardableResult
    static func removeEmptyDirectory(_ url: URL) -> Bool {
        withPath(url) { rmdir($0) == 0 ? 0 : errno } == 0
    }

    static func pathLength(_ url: URL) -> Int {
        url.withUnsafeFileSystemRepresentation { $0.map { strlen($0) } ?? Int(PATH_MAX) }
    }

    static func posixCode(of error: any Error) -> Int32? {
        if let failure = error as? POSIXFailure {
            return failure.code
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return Int32(nsError.code)
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return Int32(underlying.code)
        }
        guard nsError.domain == NSCocoaErrorDomain else { return nil }
        switch CocoaError.Code(rawValue: nsError.code) {
        case .fileWriteNoPermission, .fileReadNoPermission: return EACCES
        case .fileWriteFileExists: return EEXIST
        case .fileNoSuchFile, .fileReadNoSuchFile: return ENOENT
        case .fileWriteVolumeReadOnly: return EROFS
        default: return nil
        }
    }

    private static func withPath(_ url: URL, _ body: (UnsafePointer<CChar>) -> Int32) -> Int32 {
        url.withUnsafeFileSystemRepresentation { pointer in
            guard let pointer else { return EINVAL }
            return body(pointer)
        }
    }
}
