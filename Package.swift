// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgtmuxTerm",
    platforms: [.macOS(.v14)],
    targets: [
        // GhosttyKit.xcframework (pre-built via `scripts/build-ghosttykit.sh`)
        .binaryTarget(
            name: "GhosttyKit",
            path: "GhosttyKit/GhosttyKit.xcframework"
        ),
        // GhosttyKit/AppKit independent core logic.
        .target(
            name: "AgtmuxTermCore",
            path: "Sources/AgtmuxTermCore"
        ),
        .executableTarget(
            name: "AgtmuxTerm",
            dependencies: ["GhosttyKit", "AgtmuxTermCore"],
            path: "Sources/AgtmuxTerm",
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                // Core rendering & graphics (from pkg/macos/build.zig)
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOSurface"),
                // Text & font
                .linkedFramework("CoreText"),
                .linkedFramework("CoreFoundation"),
                // Video / display
                .linkedFramework("CoreVideo"),
                // macOS UI
                .linkedFramework("AppKit"),
                .linkedFramework("Foundation"),
                // Carbon (for keyboard handling)
                .linkedFramework("Carbon"),
                // Notifications
                .linkedFramework("UserNotifications"),
                // Uniform Type Identifiers
                .linkedFramework("UniformTypeIdentifiers"),
                // Web content companion surfaces
                .linkedFramework("WebKit"),
                // i18n (libintl bundled in xcframework)
                .linkedLibrary("iconv"),
                // C++ standard library (required by libghostty.a — glslang, spirv-cross, etc.)
                .linkedLibrary("c++"),
            ]
        ),
        .testTarget(
            name: "AgtmuxTermCoreTests",
            dependencies: ["AgtmuxTermCore"],
            path: "Tests/AgtmuxTermCoreTests"
        ),
        .testTarget(
            name: "AgtmuxTermIntegrationTests",
            dependencies: ["AgtmuxTerm", "AgtmuxTermCore"],
            path: "Tests/AgtmuxTermIntegrationTests"
        ),
    ]
)
