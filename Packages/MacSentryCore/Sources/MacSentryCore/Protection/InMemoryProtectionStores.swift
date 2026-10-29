import Foundation

public actor InMemoryNeverTouchStore: NeverTouchStore {
    private var records: [NeverTouchPattern] = []
    private var nextID: Int64 = 1

    public init(patterns: [String] = []) {
        for pattern in patterns {
            records.append(NeverTouchPattern(id: nextID, pattern: pattern, createdAt: Date(timeIntervalSince1970: 0)))
            nextID += 1
        }
    }

    public func patterns() -> [NeverTouchPattern] {
        records
    }

    public func add(_ pattern: String, note: String?) throws(ProtectionStoreError) {
        let value = try ProtectionInput.pattern(pattern)
        guard !records.contains(where: { $0.pattern == value }) else { throw .duplicatePattern(value) }
        records.append(NeverTouchPattern(id: nextID, pattern: value, note: ProtectionInput.note(note), createdAt: Date()))
        nextID += 1
    }

    public func remove(id: Int64) {
        records.removeAll { $0.id == id }
    }
}

public actor InMemoryIgnoredPathStore: IgnoredPathStore {
    private var records: [IgnoredPath] = []

    public init(urls: [URL] = []) {
        records = urls.map { IgnoredPath(url: $0, createdAt: Date(timeIntervalSince1970: 0)) }
    }

    public func paths() -> [IgnoredPath] {
        records
    }

    public func add(_ url: URL) {
        guard !records.contains(where: { $0.url.storagePath == url.storagePath }) else { return }
        records.append(IgnoredPath(url: url, createdAt: Date()))
    }

    public func remove(_ url: URL) {
        records.removeAll { $0.url.storagePath == url.storagePath }
    }
}
