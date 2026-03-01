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
        .executableTarget(
            name: "AgtmuxTerm",
            dependencies: ["GhosttyKit"],
            path: "Sources/AgtmuxTerm",
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
                // i18n (libintl bundled in xcframework)
                .linkedLibrary("iconv"),
            ]
        ),
    ]
)
