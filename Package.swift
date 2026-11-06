// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RDPGate",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "RDPGate", path: "Sources/RDPGate")
    ]
)
