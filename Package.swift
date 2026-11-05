// swift-tools-version:6.4
import PackageDescription

let package = Package(
    name: "ItJustTalks",
    platforms: [
        .macOS(.v27)
    ],
    targets: [
        .executableTarget(
            name: "ItJustTalks",
            dependencies: ["ItJustTalksAI"],
            path: "Sources/ItJustTalks",
            resources: [
                .copy("Resources/prompts"),
                .copy("Resources/ja.lproj"),
                .copy("Resources/en.lproj")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "AFMBackgroundProbe",
            path: "Tools/AFMBackgroundProbe",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "ItJustTalksAI",
            path: "Sources/ItJustTalksAI",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "afm-eval",
            dependencies: ["ItJustTalksAI"],
            path: "Tools/afm-eval",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "ItJustTalksAITests",
            dependencies: ["ItJustTalksAI"],
            path: "Tests/ItJustTalksAITests"
        ),
        .testTarget(
            name: "ItJustTalksAppTests",
            dependencies: ["ItJustTalks", "ItJustTalksAI"],
            path: "Tests/ItJustTalksAppTests"
        )
    ]
)
