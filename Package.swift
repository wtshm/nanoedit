// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "nanoedit",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/raspu/Highlightr.git", from: "2.2.1"),
    ],
    targets: [
        .executableTarget(
            name: "nanoedit",
            dependencies: ["Highlightr"],
            path: "Sources/NanoEdit"
        ),
    ]
)
