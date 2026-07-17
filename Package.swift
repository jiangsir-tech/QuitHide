// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuitHide",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "QuitHide", targets: ["QuitHide"])
    ],
    targets: [
        .executableTarget(
            name: "QuitHide",
            path: "Sources/QuitHide"
        ),
        .testTarget(
            name: "QuitHideTests",
            dependencies: ["QuitHide"],
            path: "Tests/QuitHideTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
