// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "MdCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MdCore", targets: ["MdCore"]),
    ],
    targets: [
        // Built by scripts/build-xcframework.sh.
        .binaryTarget(name: "DewlineFFI", path: "DewlineFFI.xcframework"),
        .target(
            name: "DewlineFFIBindings",
            dependencies: ["DewlineFFI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "MdCore",
            dependencies: ["DewlineFFIBindings"],
            swiftSettings: [.treatAllWarnings(as: .error)]
        ),
    ]
)
