// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FocusTracker",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "FocusTracker",
            path: "Sources/FocusTracker"
        ),
        .testTarget(
            name: "FocusTrackerTests",
            dependencies: ["FocusTracker"],
            path: "Tests/FocusTrackerTests"
        ),
    ]
)
