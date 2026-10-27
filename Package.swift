// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RemoteMyMac",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CVirtualDisplay", path: "Sources/CVirtualDisplay"),
        .executableTarget(name: "remotemymac", dependencies: ["CVirtualDisplay"], path: "Sources/remotemymac")
    ]
)
