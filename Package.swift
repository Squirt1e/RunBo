// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RunBo",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RunBo", targets: ["App"]),
        .executable(name: "runbo-checks", targets: ["Checks"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0")
    ],
    targets: [
        .target(
            name: "Core",
            path: "src/core",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "App",
            dependencies: [
                "Core",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "src/app",
            resources: [.process("Assets")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Checks",
            dependencies: ["Core"],
            path: "src/checks",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
