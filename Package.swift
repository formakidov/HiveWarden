// swift-tools-version:6.0
import PackageDescription

// "ClaudeWorkers" is the internal code name; the app users see is called HiveWarden
// (see AppInfo.name and scripts/build-app.sh).
let package = Package(
    name: "ClaudeWorkers",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ClaudeWorkers", targets: ["ClaudeWorkers"])],
    targets: [
        .target(name: "ClaudeWorkersCore"),
        .executableTarget(name: "ClaudeWorkers", dependencies: ["ClaudeWorkersCore"]),
        .testTarget(name: "ClaudeWorkersCoreTests", dependencies: ["ClaudeWorkersCore"]),
    ],
    swiftLanguageModes: [.v5]
)
