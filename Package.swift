// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// Three parts in one package:
//   NotchCore   the notch window, the study timer and its data files (shared library)
//   ApexAgent   the voice agent (mic, LLM, TTS, Mac actions); shows its state in the notch
//   StudyNotch  the study notch on its own, for other Mac users (no mic, no keys, no shell)
let package = Package(
    name: "ApexAgent",
    // Speech, WebSocket and AVAudioEngine APIs all need a modern macOS; without this the
    // package defaults to an old minimum and every newer API needs an @available annotation.
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ApexAgent", targets: ["ApexAgent"]),
        .executable(name: "StudyNotch", targets: ["StudyNotch"]),
        .library(name: "NotchCore", targets: ["NotchCore"]),
    ],
    targets: [
        .target(name: "NotchCore"),
        .executableTarget(
            name: "ApexAgent",
            dependencies: ["NotchCore"],
            exclude: ["Info.plist"],
            resources: [.copy("prompts")],
            // Embed Info.plist in the binary: macOS requires the speech-recognition usage description
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Sources/ApexAgent/Info.plist"])
            ]
        ),
        // No Info.plist: StudyNotch asks for no permissions at all
        .executableTarget(name: "StudyNotch", dependencies: ["NotchCore"]),
        .testTarget(name: "ApexAgentTests", dependencies: ["ApexAgent"]),
        .testTarget(name: "NotchCoreTests", dependencies: ["NotchCore"]),
    ],
    swiftLanguageModes: [.v6]
)
