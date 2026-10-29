import Foundation

enum GitMetadata {
    static let reflogTailBytes: UInt64 = 8192

    static func gitDirectory(forRoot root: URL, probe: any ProjectFileProbe) -> URL? {
        let dotGit = root.appending(path: ".git")
        if probe.isDirectory(at: dotGit) {
            return dotGit
        }
        guard probe.itemExists(at: dotGit),
              let text = try? String(contentsOf: dotGit, encoding: .utf8)
        else { return nil }
        return parseGitFile(text, relativeTo: root)
    }

    static func parseGitFile(_ text: String, relativeTo root: URL) -> URL? {
        let prefix = "gitdir:"
        guard let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix(prefix) }) else { return nil }
        let path = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("/") {
            return URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
        }
        return root.appending(path: path, directoryHint: .isDirectory).standardizedFileURL
    }

    static func reflogDate(gitDirectory: URL) -> Date? {
        let url = gitDirectory.appending(path: "logs/HEAD")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > reflogTailBytes ? end - reflogTailBytes : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd()
        else { return nil }
        // The tail can start mid UTF-8 sequence; Latin-1 always decodes and keeps the ASCII timestamp intact.
        return parseLastReflogTimestamp(String(bytes: data, encoding: .utf8) ?? String(bytes: data, encoding: .isoLatin1) ?? "")
    }

    static func parseLastReflogTimestamp(_ text: String) -> Date? {
        guard let line = text.split(whereSeparator: \.isNewline).last(where: { !$0.allSatisfy(\.isWhitespace) }) else { return nil }
        let header = line.split(separator: "\t", maxSplits: 1).first ?? line
        // Field 5 by whitespace breaks on committer names with spaces, so anchor on the email's closing bracket.
        guard let close = header.lastIndex(of: ">") else { return nil }
        let fields = header[header.index(after: close)...].split(whereSeparator: \.isWhitespace)
        guard let first = fields.first, let seconds = TimeInterval(first) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
