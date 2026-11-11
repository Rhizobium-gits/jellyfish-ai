// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "JellyfishAI",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "JellyfishAI",
            path: "Sources/JellyfishAI",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        )
    ]
)
