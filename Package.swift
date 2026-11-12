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
        ),
        // 画面や claude を使わない部分（設定の読み込み・判定ロジック）のテスト。`swift test` で実行（Xcode 不要）
        .testTarget(
            name: "JellyfishAITests",
            dependencies: ["JellyfishAI"],
            path: "Tests/JellyfishAITests"
        ),
    ]
)
