// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "AIEverything",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AIEPopup", targets: ["AIEPopup"]),
        .library(name: "AIEData", targets: ["AIEData"]),
        .executable(name: "AIEDataChecks", targets: ["AIEDataChecks"]),
        .executable(name: "AIEMediaChecks", targets: ["AIEMediaChecks"]),
    ],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1")],
    targets: [
        .target(name: "AIEData", dependencies: [.product(name: "GRDB", package: "GRDB.swift")], path: "core/AIEData"),
        .target(name: "AIEMedia", dependencies: ["AIEData"], path: "core/AIEMedia"),
        .executableTarget(name: "AIEPopup", dependencies: ["AIEData", "AIEMedia"], path: "apps/macos/AIEPopup/Sources"),
        .executableTarget(name: "AIEDataChecks", dependencies: ["AIEData"], path: "tests/DataLayer"),
        .executableTarget(name: "AIEMediaChecks", dependencies: ["AIEMedia"], path: "tests/MediaBackend"),
    ],
    swiftLanguageModes: [.v5]
)
