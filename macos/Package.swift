// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "appring-macos",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "appring", targets: ["appring"]),
    ],
    targets: [
        .target(name: "AppringCore"),
        .executableTarget(
            name: "appring",
            dependencies: ["AppringCore"],
            resources: [.process("default.json")]
        ),
        // Not XCTest: the Command Line Tools don't have that framework; the runner starts with swift run.
        .executableTarget(name: "appring-core-tests", dependencies: ["AppringCore"]),
    ]
)
