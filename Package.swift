// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "nanoedit",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/smittytone/HighlighterSwift.git", from: "3.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "nanoedit",
            dependencies: [.product(name: "Highlighter", package: "highlighterswift")],
            path: "Sources/NanoEdit"
        ),
    ]
)
