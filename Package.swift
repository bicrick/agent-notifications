// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "AgentDots",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "AgentDots", path: "Sources/AgentDots")
    ]
)
