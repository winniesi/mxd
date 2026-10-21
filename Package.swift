// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "mxd",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "mxd",
            path: "Sources/mxd",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
            ]
        )
    ]
)
