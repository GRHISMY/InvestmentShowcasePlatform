// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CompanyLens",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ResearchCore", targets: ["ResearchCore"]),
        .executable(name: "CompanyLens", targets: ["CompanyLens"])
    ],
    targets: [
        .target(name: "ResearchCore", path: "Core"),
        .executableTarget(
            name: "CompanyLens", dependencies: ["ResearchCore"], path: ".",
            exclude: ["Core", "Tests", "UITests", "Tools", "Configuration", "App/Assets.xcassets", "App/Info.plist", "CompanyLens.xcodeproj", "README.md", "Verification"],
            sources: ["App"], resources: [.copy("Study")]
        ),
        .testTarget(name: "ResearchCoreTests", dependencies: ["ResearchCore"], path: "Tests")
    ]
)
