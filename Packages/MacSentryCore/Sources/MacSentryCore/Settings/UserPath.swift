import Foundation

public enum UserPath {
    public static func expand(_ text: String, homeURL: URL) -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "~" {
            return homeURL.standardizedFileURL
        }
        if trimmed.hasPrefix("~/") {
            return homeURL.appending(path: String(trimmed.dropFirst(2))).standardizedFileURL
        }
        if trimmed.hasPrefix("/") {
            return URL(filePath: trimmed).standardizedFileURL
        }
        return homeURL.appending(path: trimmed).standardizedFileURL
    }

    public static func abbreviate(_ url: URL, homeURL: URL) -> String {
        let path = url.storagePath
        let home = homeURL.storagePath
        if path == home {
            return "~"
        }
        if home != "/", path.hasPrefix(home + "/") {
            return "~/" + path.dropFirst(home.count + 1)
        }
        return path
    }
}
