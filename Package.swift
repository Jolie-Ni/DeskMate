// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ObserverDaemon",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.27.0"),
    ],
    targets: [
        .target(
            name: "ObserverCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "ObserverDaemon",
            dependencies: ["ObserverCore"]
        ),
        .target(
            name: "ObserverAnalyzer",
            dependencies: ["ObserverCore"]
        ),
        // Builds test fixtures from external corpora. Uses the real OCR,
        // Redactor and Storage so a fixture is produced by the same code the
        // daemon runs — a harness that reimplemented them would drift.
        .executableTarget(
            name: "ObserverFixture",
            dependencies: ["ObserverCore", "ObserverAnalyzer"]
        ),
        .executableTarget(
            name: "ObserverDashboard",
            dependencies: ["ObserverCore", "ObserverAnalyzer"]
        ),
    ]
)
