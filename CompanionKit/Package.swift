// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CompanionKit",
    platforms: [.macOS("26.0"), .iOS(.v17)],
    products: [.library(name: "CompanionKit", targets: ["CompanionKit"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.0.0")
    ],
    targets: [
        .target(name: "CompanionKit", dependencies: [
            .product(name: "X509", package: "swift-certificates", condition: .when(platforms: [.macOS]))
        ])
    ]
)
