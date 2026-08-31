// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DeskMate",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.27.0"),
    ],
    targets: [
        .target(
            name: "DeskMateCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "DeskMateDaemon",
            dependencies: ["DeskMateCore"]
        ),
        .target(
            name: "DeskMateAnalyzer",
            dependencies: ["DeskMateCore"]
        ),
        // Builds test fixtures from external corpora. Uses the real OCR,
        // Redactor and Storage so a fixture is produced by the same code the
        // daemon runs — a harness that reimplemented them would drift.
        .executableTarget(
            name: "DeskMateFixture",
            dependencies: ["DeskMateCore", "DeskMateAnalyzer"]
        ),
        // What the daily cron runs. Its own binary rather than a flag on the
        // fixture harness: a job that runs unattended every night should not
        // share a process with test tooling.
        .executableTarget(
            name: "DeskMateSummary",
            dependencies: ["DeskMateCore", "DeskMateAnalyzer"]
        ),
        .executableTarget(
            name: "DeskMateDashboard",
            dependencies: ["DeskMateCore", "DeskMateAnalyzer"]
        ),
    ]
)
