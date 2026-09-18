// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Vulpine",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Vulpine", targets: ["Vulpine"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "Vulpine",
            path: "Vulpine",
            exclude: ["Resources", "Info.plist", "Vulpine.entitlements"]
        )
    ]
)
