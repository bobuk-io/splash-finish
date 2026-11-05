// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SplashFinish",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SplashFinish", targets: ["SplashFinish"])],
    targets: [
        .target(name: "SplashFinishCore"),
        .executableTarget(name: "SplashFinish", dependencies: ["SplashFinishCore"],
                          resources: [.copy("Resources/Integrations")]),
        .testTarget(name: "SplashFinishCoreTests", dependencies: ["SplashFinishCore"])
    ]
)
