import Foundation

public struct AppEnvironment: Sendable, Equatable {
    public static let scanRootArgument = "MacSentryScanRoot"
    public static let dryRunArgument = "MacSentryDryRun"
    public static let databasePathArgument = "MacSentryDatabasePath"

    public let scanRoot: URL?
    public let isDryRun: Bool
    public let databasePathOverride: URL?
    public let homeURL: URL
    public let databaseURL: URL

    public init(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        realHomeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    ) {
        let values = Self.parse(arguments)
        scanRoot = values[Self.scanRootArgument].map { URL(filePath: $0, directoryHint: .isDirectory).absoluteURL.standardizedFileURL }
        isDryRun = values[Self.dryRunArgument].map(Self.parseBool) ?? false
        databasePathOverride = values[Self.databasePathArgument]
            .map { URL(filePath: $0, directoryHint: .notDirectory).absoluteURL.standardizedFileURL }
        homeURL = scanRoot ?? realHomeURL
        databaseURL = databasePathOverride ?? realHomeURL.appending(
            path: "Library/Application Support/MacSentry/macsentry.sqlite",
            directoryHint: .notDirectory,
        )
    }

    private static func parse(_ arguments: [String]) -> [String: String] {
        let keys: Set = [scanRootArgument, dryRunArgument, databasePathArgument]
        var values: [String: String] = [:]
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            let next = arguments.index(after: index)
            if argument.hasPrefix("-"), keys.contains(String(argument.dropFirst())), next < arguments.endIndex {
                let value = arguments[next]
                values[String(argument.dropFirst())] = value.isEmpty ? nil : value
                index = arguments.index(after: next)
            } else {
                index = next
            }
        }
        return values
    }

    private static func parseBool(_ value: String) -> Bool {
        ["yes", "true", "1"].contains(value.lowercased())
    }
}
