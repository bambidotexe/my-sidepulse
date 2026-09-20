// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "my-sidepulse",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "MySidepulseApp", targets: ["MySidepulseApp"]),
        .executable(name: "mysidepulse", targets: ["MySidepulseCLI"]),
    ],
    targets: [
        .target(name: "MySidepulseCore"),
        .target(name: "MySidepulsePlatform", dependencies: ["MySidepulseCore"]),
        .executableTarget(name: "MySidepulseApp", dependencies: ["MySidepulseCore", "MySidepulsePlatform"]),
        .executableTarget(name: "MySidepulseCLI", dependencies: ["MySidepulseCore", "MySidepulsePlatform"]),
        .testTarget(name: "MySidepulseCoreTests", dependencies: ["MySidepulseCore"]),
        // MySidepulseCore is declared explicitly: two of these test files
        // @testable import it, and relying on SwiftPM's transitive module
        // search path for that is incidental, not a guarantee.
        .testTarget(name: "MySidepulsePlatformTests",
                    dependencies: ["MySidepulsePlatform", "MySidepulseCore"]),
    ]
)
