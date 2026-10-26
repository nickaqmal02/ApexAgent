// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ApexAgent",
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "ApexAgent",
            exclude: ["Info.plist"],
            resources: [.copy("prompts")]
        ),
        .testTarget(
            name: "ApexAgentTests",
            dependencies: ["ApexAgent"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
