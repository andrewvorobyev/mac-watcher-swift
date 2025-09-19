// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "mac-watcher-swift",
    products: [
        .executable(name: "capture", targets: ["capture"]),
        .executable(name: "observe", targets: ["observe"])
    ],
    targets: [
        .executableTarget(name: "capture"),
        .executableTarget(name: "observe")
    ]
)
