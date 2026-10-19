// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TerminalDeck",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RunBo", targets: ["TerminalDeck"]),
        .executable(name: "runbo-checks", targets: ["TerminalDeckChecks"]),
        .library(name: "TerminalDeckKit", targets: ["TerminalDeckKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0")
    ],
    targets: [
        .target(
            name: "TerminalDeckKit",
            path: "Sources/TerminalDeckKit",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "TerminalDeck",
            dependencies: [
                "TerminalDeckKit",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/TerminalDeck",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "TerminalDeckChecks",
            dependencies: ["TerminalDeckKit"],
            path: "Sources/TerminalDeckChecks",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
