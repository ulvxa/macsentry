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
        presence(of: url) != false
    }

    static func presence(of url: URL) -> Bool? {
        do {
            _ = try status(of: url)
            return true
        } catch {
            return error.code == ENOENT || error.code == ENOTDIR ? false : nil
        }
    }

    static func realPath(_ url: URL) throws(POSIXFailure) -> String {
        var code: Int32 = 0
        let resolved: String? = url.withUnsafeFileSystemRepresentation { pointer in
            guard let pointer, let real = realpath(pointer, nil) else {
                code = errno
                return nil
            }
            defer { free(real) }
            return String(cString: real)
        }
        guard let resolved else { throw POSIXFailure(code: code == 0 ? EINVAL : code) }
        return resolved
    }

    static func appendLine(_ data: Data, to url: URL) throws(POSIXFailure) {
        let descriptor = url.withUnsafeFileSystemRepresentation { pointer in
            pointer.map { open($0, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644) } ?? -1
        }
        guard descriptor >= 0 else { throw POSIXFailure(code: errno) }
        defer { close(descriptor) }
        let line = data + Data([0x0A])
        let written = line.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        guard written == line.count else { throw POSIXFailure(code: written < 0 ? errno : EIO) }
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
