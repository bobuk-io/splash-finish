// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SplashFinish",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SplashFinish", targets: ["SplashFinish"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
    targets: [
        .target(name: "SplashFinishCore"),
        .executableTarget(name: "SplashFinish", dependencies: ["SplashFinishCore", .product(name: "Sparkle", package: "Sparkle")],
                          resources: [.copy("Resources/Integrations")]),
        .testTarget(name: "SplashFinishCoreTests", dependencies: ["SplashFinishCore"])
    ]
)
