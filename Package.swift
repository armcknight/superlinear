// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "superlinear",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-tagged", from: "0.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "superlinear",
            dependencies: [.product(name: "Tagged", package: "swift-tagged")],
            path: "Sources/superlinear"
        ),
        .testTarget(
            name: "superlinearTests",
            dependencies: ["superlinear", .product(name: "Tagged", package: "swift-tagged")],
            path: "Tests/superlinearTests"
        )
    ]
)
