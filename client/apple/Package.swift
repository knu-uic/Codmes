// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodmesApple",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .executable(name: "Codmes", targets: ["Codmes"])
    ],
    targets: [
        .executableTarget(
            name: "Codmes",
            path: "Sources/Codmes"
        ),
        .testTarget(
            name: "CodmesTests",
            dependencies: ["Codmes"]
        )
    ]
)
