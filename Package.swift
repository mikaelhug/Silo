// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Silo",
    platforms: [.macOS(.v15)],
    targets: [
        // Thin executable: defers entirely to SiloKit (so all logic stays testable).
        .executableTarget(
            name: "silo",
            dependencies: ["SiloKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // All app logic + views live here so the test target can import them.
        .target(
            name: "SiloKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SiloKitTests",
            dependencies: ["SiloKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
