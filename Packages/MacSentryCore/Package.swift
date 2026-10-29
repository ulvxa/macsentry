// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MacSentryCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MacSentryCore", targets: ["MacSentryCore"]),
        .library(name: "MacSentryTestSupport", targets: ["MacSentryTestSupport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.0"),
    ],
    targets: [
        .target(
            name: "MacSentryCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            resources: [.copy("Resources/Rules")],
        ),
        .target(name: "MacSentryTestSupport"),
        .testTarget(
            name: "MacSentryCoreTests",
            dependencies: ["MacSentryCore", "MacSentryTestSupport"],
        ),
    ],
)
