// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ApexAgent",
    // Speech, WebSocket and AVAudioEngine APIs all need a modern macOS; without this the
    // package defaults to an old minimum and every newer API needs an @available annotation.
    platforms: [.macOS(.v13)],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "ApexAgent",
            exclude: ["Info.plist"],
            resources: [.copy("prompts")],
            // Embed Info.plist in the binary: macOS requires the speech-recognition usage description
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Sources/ApexAgent/Info.plist"])
            ]
        ),
        .testTarget(
            name: "ApexAgentTests",
            dependencies: ["ApexAgent"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
