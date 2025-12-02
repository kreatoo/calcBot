// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "calcBot",
    dependencies: [
        .package(url: "https://github.com/soulverteam/SoulverCore", from: "3.2.1"),
        .package(url: "https://github.com/DiscordBM/DiscordBM", from: "1.10.1")
    ],
    targets: [
        .executableTarget(
            name: "calcBot",
            dependencies: [
                .product(name: "SoulverCore", package: "SoulverCore", condition: .when(platforms: [.macOS])),
                .product(name: "DiscordBM", package: "DiscordBM")
            ],
            path: "calcBot",
            swiftSettings: [
                // On Linux, use the module interfaces from Vendor directory
                .unsafeFlags(["-I", "Vendor/SoulverCore-linux/Modules"], .when(platforms: [.linux]))
            ],
            linkerSettings: [
                // On Linux, link against the dynamic library from Vendor directory
                .linkedLibrary("SoulverCoreDynamic", .when(platforms: [.linux])),
                .unsafeFlags([
                    "-L", "Vendor/SoulverCore-linux",
                    "-Xlinker", "-rpath", "-Xlinker", "$ORIGIN/../Vendor/SoulverCore-linux"
                ], .when(platforms: [.linux]))
            ]
        )
    ]
)
