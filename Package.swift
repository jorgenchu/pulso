// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Pulso",
    platforms: [.macOS(.v14)],
    targets: [
        // Thin C shim over the pieces that have no Swift-importable API:
        // AppleSMC, the private IOHID sensor calls and the 64-bit interface counters.
        .target(
            name: "CPulso",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        // Metric readers and the sampling engine. No UI.
        .target(
            name: "PulsoCore",
            dependencies: ["CPulso"],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("SystemConfiguration")]
        ),
        // Command-line front end to the engine, used to inspect and benchmark it.
        .executableTarget(name: "pulsoctl", dependencies: ["PulsoCore"]),
        // Root helper that sets fan speeds for the app. Installed with scripts/install-fan-helper.sh.
        .executableTarget(name: "pulso-fand", dependencies: ["PulsoCore"]),
        // The menu bar app.
        .executableTarget(name: "Pulso", dependencies: ["PulsoCore"]),
        .testTarget(name: "PulsoCoreTests", dependencies: ["PulsoCore"]),
    ]
)
