// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "opentypeno",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "OpenTypeNo", targets: ["OpenTypeNo"])
    ],
    targets: [
        .executableTarget(
            name: "OpenTypeNo",
            path: "Sources/Typeno",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "App/Info.plist"
                ])
            ]
        )
    ]
)
