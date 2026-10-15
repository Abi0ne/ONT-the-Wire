// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ONTTheWire",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "ONTTheWireCore",
            linkerSettings: [
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "ONTTheWire",
            dependencies: ["ONTTheWireCore"]
        ),
        // PPPoE transport for pppd (BPF + 802.1Q), run as root by the app.
        .executableTarget(
            name: "pppoe-relay",
            cSettings: [.unsafeFlags(["-Wall", "-Wextra"])]
        ),
        // Becomes fully root after AuthorizationExecuteWithPrivileges and runs the broker.
        .executableTarget(
            name: "ont-root-helper",
            cSettings: [.unsafeFlags(["-Wall", "-Wextra"])]
        ),
        .testTarget(
            name: "ONTTheWireCoreTests",
            dependencies: ["ONTTheWireCore"]
        ),
    ],
    // SystemConfiguration's C callbacks and CF types are not annotated for
    // Swift 6 strict concurrency; v5 mode keeps the bridging code readable.
    swiftLanguageModes: [.v5]
)
