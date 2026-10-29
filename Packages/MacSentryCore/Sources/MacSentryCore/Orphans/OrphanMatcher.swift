import Foundation

struct OlderVersion: Equatable {
    let product: String
    let folderVersion: String
    let currentVersion: String
    let app: InstalledApp
}

struct OrphanMatcher {
    private let apps: [InstalledApp]
    private let knownIDs: Set<String>
    private let knownVendors: Set<String>
    private let knownNames: Set<String>
    private let appleNames: Set<String>
    private let systemNames: Set<String>
    private let appleTokens: [String: String]

    init(apps: [InstalledApp], extraIDs: Set<String>, allowlist: SystemAllowlist, appleTokens: [String: String] = [:]) {
        self.apps = apps
        let ids = Set((apps.map(\.bundleID) + extraIDs).map { $0.lowercased() }.filter { !$0.isEmpty })
        knownIDs = ids
        knownVendors = Set(ids.compactMap(Self.vendor))
        func names(_ apps: [InstalledApp]) -> Set<String> {
            Set(apps.flatMap { [$0.name, $0.url.deletingPathExtension().lastPathComponent] }.map(Self.normalize).filter { !$0.isEmpty })
        }
        let apple = apps.filter(AppleAppIdentifiers.isApple)
        knownNames = names(apps.filter { !AppleAppIdentifiers.isApple($0) })
        appleNames = names(apple)
        systemNames = allowlist.activeNames(installedBundleIDs: apps.map(\.bundleID))
        self.appleTokens = appleTokens
    }

    func isSystem(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("com.apple.") || systemNames.contains { lower == $0 || lower.hasPrefix($0 + ".") }
    }

    func isKnownID(_ identity: String) -> Bool {
        let lower = identity.lowercased()
        if knownIDs.contains(lower) {
            return true
        }
        let isVendorLike = Self.isReverseDNS(lower)
        return knownIDs.contains { lower.hasPrefix($0 + ".") || (isVendorLike && $0.hasPrefix(lower + ".")) }
    }

    func matchesKnownName(_ identity: String) -> Bool {
        let normalized = Self.normalize(identity)
        guard !normalized.isEmpty else { return false }
        // Apple app names are common words (Home, Mail, Dock), so a substring would hide real leftovers like docker.
        return appleNames.contains(normalized) || knownNames.contains { $0 == normalized || ($0.count >= 4 && normalized.contains($0)) }
    }

    func isInsideInstalledApp(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return apps.contains { app in
            var appPath = app.url.standardizedFileURL.path(percentEncoded: false)
            if !appPath.hasSuffix("/") {
                appPath += "/"
            }
            return path.hasPrefix(appPath)
        }
    }

    func confidence(for identity: String) -> Confidence {
        guard let vendor = Self.vendor(identity.lowercased()) else { return .low }
        return knownVendors.contains(vendor) || sharedAppleApp(for: identity) != nil ? .medium : .high
    }

    func sharedAppleApp(for identity: String) -> String? {
        guard Self.isReverseDNS(identity) else { return nil }
        let parts = identity.lowercased().split(separator: ".")
        return appleTokens[String(parts[1])]
    }

    func sharedVendor(for identity: String) -> String? {
        guard let vendor = Self.vendor(identity.lowercased()), knownVendors.contains(vendor) else { return nil }
        return vendor
    }

    func olderVersion(name: String, parent: String?, siblings: [String]) -> OlderVersion? {
        guard let folder = Self.versionedName(name, parent: parent) else { return nil }
        let product = Self.normalize(folder.product)
        guard product.count >= 3 else { return nil }
        let owners = apps.filter {
            let appName = Self.normalize($0.name)
            return appName == product || (product.count >= 4 && appName.hasPrefix(product))
        }
        guard !owners.isEmpty else { return nil }

        let installed = owners.compactMap { app in
            app.version.flatMap(Self.versionNumbers).map { (app: app, numbers: $0) }
        }
        let current: (app: InstalledApp, numbers: [Int])
        if let newest = installed.max(by: { Self.compare($0.numbers, $1.numbers) < 0 }) {
            current = newest
        } else {
            let siblingVersions = siblings.compactMap { Self.versionedName($0, parent: parent) }
                .filter { Self.normalize($0.product) == product }
                .map(\.numbers)
            guard let newest = siblingVersions.max(by: { Self.compare($0, $1) < 0 }), let owner = owners.first else { return nil }
            current = (owner, newest)
        }

        let reference = Array(current.numbers.prefix(folder.numbers.count))
        guard Self.compare(folder.numbers, reference) < 0 else { return nil }
        return OlderVersion(
            product: folder.product,
            folderVersion: folder.text,
            currentVersion: current.numbers.map(String.init).joined(separator: "."),
            app: current.app,
        )
    }

    static func normalize(_ value: String) -> String {
        String(String.UnicodeScalarView(value.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
    }

    static func isReverseDNS(_ value: String) -> Bool {
        let parts = value.lowercased().split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let first = parts.first, first.count >= 2,
              first.allSatisfy({ $0.isASCII && $0.isLetter })
        else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }

    static func vendor(_ value: String) -> String? {
        guard isReverseDNS(value) else { return nil }
        return value.lowercased().split(separator: ".").prefix(2).joined(separator: ".")
    }

    static func guessedAppName(for identity: String) -> String {
        guard isReverseDNS(identity) else { return identity }
        let parts = identity.split(separator: ".")
        return String(parts.count > 2 ? parts[2] : parts[parts.count - 1])
    }

    static func versionNumbers(_ value: String) -> [Int]? {
        guard let start = value.firstIndex(where: { $0.isASCII && $0.isNumber }) else { return nil }
        let run = value[start...].prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
        let numbers = run.split(separator: ".").compactMap { Int($0) }
        return numbers.isEmpty ? nil : numbers
    }

    private struct VersionedName {
        let product: String
        let text: String
        let numbers: [Int]
    }

    private static func versionedName(_ name: String, parent: String?) -> VersionedName? {
        var text = String(name.reversed().prefix { $0.isASCII && ($0.isNumber || $0 == ".") }.reversed())
        while text.hasPrefix(".") {
            text.removeFirst()
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        let product = String(name.dropLast(text.count)).trimmingCharacters(in: CharacterSet(charactersIn: " _-."))
        if product.isEmpty {
            guard let parent else { return nil }
            return VersionedName(product: parent, text: text, numbers: numbers)
        }
        return VersionedName(product: product, text: text, numbers: numbers)
    }

    private static func compare(_ lhs: [Int], _ rhs: [Int]) -> Int {
        for index in 0 ..< max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right {
                return left < right ? -1 : 1
            }
        }
        return 0
    }
}

enum AppHelperIdentifiers {
    private static let helperFolders = [
        "Contents/Library/LoginItems",
        "Contents/Helpers",
        "Contents/Frameworks",
        "Contents/XPCServices",
        "Contents/PlugIns",
    ]

    static func collect(from apps: [InstalledApp]) -> Set<String> {
        var ids = Set<String>()
        for app in apps where !AppleAppIdentifiers.isApple(app) {
            for folder in helperFolders {
                let directory = app.url.appending(path: folder, directoryHint: .isDirectory)
                let children = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                for child in children {
                    if let id = bundleIdentifier(of: child) {
                        ids.insert(id)
                    }
                }
            }
        }
        return ids
    }

    private static func bundleIdentifier(of bundle: URL) -> String? {
        let plist = bundle.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return info["CFBundleIdentifier"] as? String
    }
}

/// Apple apps keep identifiers from before Apple bought them (Shortcuts still uses is.workflow), so their Info.plist names them.
enum AppleAppIdentifiers {
    static func isApple(_ app: InstalledApp) -> Bool {
        app.bundleID.lowercased().hasPrefix("com.apple.")
    }

    static func collect(from apps: [InstalledApp]) -> [String: String] {
        var tokens: [String: String] = [:]
        for app in apps where isApple(app) {
            let own = app.bundleID.lowercased().split(separator: ".")
            if own.count > 2 {
                tokens[String(own[2])] = tokens[String(own[2])] ?? app.name
            }
            for identifier in foreignIdentifiers(of: app) {
                let token = String(identifier.split(separator: ".")[1])
                tokens[token] = tokens[token] ?? app.name
            }
        }
        return tokens
    }

    private static func foreignIdentifiers(of app: InstalledApp) -> [String] {
        guard let info = DefaultOrphanDetector.plist(at: app.url.appending(path: "Contents/Info.plist")) else { return [] }
        var values = (info["CFBundleURLTypes"] as? [[String: Any]] ?? []).compactMap { $0["CFBundleURLName"] as? String }
        values += info["NSUserActivityTypes"] as? [String] ?? []
        values += (info["NSUbiquitousContainers"] as? [String: Any])?.keys.map(\.self) ?? []
        return values.map { value in
            let lower = value.lowercased()
            return lower.hasPrefix("icloud.") ? String(lower.dropFirst(7)) : lower
        }
        .filter { OrphanMatcher.isReverseDNS($0) && !$0.hasPrefix("com.apple.") }
    }
}
