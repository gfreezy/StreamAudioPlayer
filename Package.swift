// swift-tools-version: 5.8
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "StreamAudio",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "StreamAudio",
            targets: ["StreamAudio"]),
    ],
    dependencies: [
        .package(name: "Semaphore", url: "https://github.com/groue/Semaphore", revision: "b92ec84")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "StreamAudio",
            dependencies: [
                "Semaphore"
            ]
        ),
        .testTarget(
            name: "StreamAudioTests",
            dependencies: ["StreamAudio"]),
    ]
)
