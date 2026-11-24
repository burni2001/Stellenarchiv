// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Stellenarchiv",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Stellenarchiv",
            path: "Sources/Stellenarchiv"
        )
    ]
)
