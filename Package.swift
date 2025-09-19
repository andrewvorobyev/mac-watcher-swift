// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "mac-watcher-swift",
    products: [
        .executable(name: "capture", targets: ["capture"]),
        .executable(name: "observe", targets: ["observe"]),
        .executable(name: "screenshot", targets: ["screenshot"])
    ],
    targets: [
        .target(name: "CaptureSupport"),
        .executableTarget(name: "capture", dependencies: ["CaptureSupport"]),
        .executableTarget(name: "observe", dependencies: ["CaptureSupport"]),
        .executableTarget(name: "screenshot", dependencies: ["CaptureSupport"])
    ]
)
