// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ConsentCallRecorder",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ConsentCallRecorder", targets: ["ConsentCallRecorder"])
    ],
    targets: [
        .executableTarget(
            name: "ConsentCallRecorder",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AppKit")
            ]
        ),
        .testTarget(
            name: "ConsentCallRecorderTests",
            dependencies: ["ConsentCallRecorder"],
            linkerSettings: [
                .linkedFramework("AVFoundation")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
