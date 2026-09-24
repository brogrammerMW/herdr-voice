// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "herdr-voice",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "HerdrVoiceCore"),
        .executableTarget(name: "herdr-voice", dependencies: ["HerdrVoiceCore"]),
        .testTarget(name: "HerdrVoiceTests", dependencies: ["HerdrVoiceCore"]),
    ]
)
