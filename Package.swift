// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ContextRoute",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "ContextRoute", targets: ["ContextRoute"])
    ],
    targets: [
        .executableTarget(
            name: "ContextRoute",
            path: "Sources/ContextRoute")
    ],
    swiftLanguageVersions: [.v5]
)
