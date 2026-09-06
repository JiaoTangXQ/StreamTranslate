// swift-tools-version: 6.0
import PackageDescription

// Command Line Tools build path; project.yml remains the Xcode configuration.
let package = Package(
    name: "StreamTranslate",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "StreamTranslate", targets: ["StreamTranslate"]),
        .executable(name: "CompanionProbe", targets: ["CompanionProbe"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", from: "1.0.0"),
        .package(path: "CompanionKit")
    ],
    targets: [
        .executableTarget(name: "CompanionProbe",
                          dependencies: [.product(name: "CompanionKit", package: "CompanionKit")],
                          path: "Tools/CompanionProbe"),
        .target(
            name: "NemotronBridge",
            path: "StreamTranslate/Bridge",
            exclude: ["StreamTranslate-Bridging-Header.h"],
            publicHeadersPath: "."
        ),
        .executableTarget(
            name: "StreamTranslate",
            dependencies: [
                "NemotronBridge",
                .product(name: "CompanionKit", package: "CompanionKit"),
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ],
            path: "StreamTranslate",
            exclude: ["Bridge", "Resources"]
        ),
        .testTarget(
            name: "StreamTranslateTests",
            dependencies: ["StreamTranslate"],
            path: "StreamTranslateTests"
        )
    ]
)
