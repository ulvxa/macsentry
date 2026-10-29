import Foundation

public protocol ProjectFileProbe: Sendable {
    func contents(of directory: URL) -> [String]
    func itemExists(at url: URL) -> Bool
    func isDirectory(at url: URL) -> Bool
}

public struct FileManagerProjectProbe: ProjectFileProbe {
    public init() {}

    public func contents(of directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
    }

    public func itemExists(at url: URL) -> Bool {
        var info = stat()
        return lstat(url.path(percentEncoded: false), &info) == 0
    }

    public func isDirectory(at url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path(percentEncoded: false), &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFDIR
    }
}
