// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Errorgap",
    platforms: [
        .iOS(.v14),
        .macOS(.v11),
        .tvOS(.v14),
        .watchOS(.v7),
    ],
    products: [
        .library(name: "Errorgap", targets: ["Errorgap"])
    ],
    targets: [
        .target(name: "Errorgap", path: "Sources/Errorgap"),
        .testTarget(name: "ErrorgapTests", dependencies: ["Errorgap"], path: "Tests/ErrorgapTests"),
    ]
)
