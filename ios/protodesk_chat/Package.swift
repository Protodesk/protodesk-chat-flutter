// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "protodesk_chat",
    platforms: [
        .iOS("13.0")
    ],
    products: [
        .library(name: "protodesk-chat", targets: ["protodesk_chat"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "protodesk_chat",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                // Declares the file-metadata reads behind protected attachments.
                .process("PrivacyInfo.xcprivacy")
            ]
        )
    ]
)
