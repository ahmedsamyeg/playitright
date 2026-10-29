// swift-tools-version: 6.0
import PackageDescription

// PlayItRight core: platform-neutral SPM packages (ARCH-P2, ARCH-7).
// The tvOS app shell consumes these; macOS/iOS builds exist for CI + companion.
let package = Package(
    name: "PlayItRightCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .tvOS(.v17)
    ],
    products: [
        .library(name: "LibraryCore", targets: ["LibraryCore"]),
        .library(name: "PlaybackSpike", targets: ["PlaybackSpike"])
    ],
    dependencies: [
        // SQLite with FTS5/JSON1; the on-device media database engine (doc 02, design 01).
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "LibraryCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .target(
            name: "PlaybackSpike",
            dependencies: []
        ),
        .testTarget(
            name: "LibraryCoreTests",
            dependencies: ["LibraryCore"],
            swiftSettings: [
                .unsafeFlags(["-F/Library/Developer/CommandLineTools/Library/Developer/Frameworks"])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
                ])
            ]
        ),
        .testTarget(
            name: "PlaybackSpikeTests",
            dependencies: ["PlaybackSpike"],
            swiftSettings: [
                .unsafeFlags(["-F/Library/Developer/CommandLineTools/Library/Developer/Frameworks"])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
                ])
            ]
        )
    ]
)
