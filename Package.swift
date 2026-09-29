// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NTFSAssistant",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "NTFSAssistant",
            targets: ["NTFSAssistant"]
        )
    ],
    targets: [
        .executableTarget(
            name: "NTFSAssistant",
            path: "Sources/NTFSAssistant",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("DiskArbitration"),
                .linkedFramework("IOKit")
            ]
        )
    ]
)
