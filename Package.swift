// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuitHide",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "QuitHide", targets: ["QuitHide"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            exact: "2.9.4"
        )
    ],
    targets: [
        .executableTarget(
            name: "QuitHide",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/QuitHide",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "QuitHideTests",
            dependencies: ["QuitHide"],
            path: "Tests/QuitHideTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
