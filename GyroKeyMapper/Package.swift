// swift-tools-version:5.9
import PackageDescription

// Correctness checks live in Checks/ and run via `bash Checks/run.sh`, not as a
// SwiftPM test target: XCTest ships with Xcode and the swift-testing library
// isn't in the Command Line Tools either, so a `.testTarget` cannot build here.
// See Checks/main.swift for what is covered and why.
let package = Package(
    name: "GyroKeyMapper",
    platforms: [.macOS(.v11)],
    targets: [
        // Vendored from https://github.com/magicien/JoyConSwift (MIT license,
        // see Sources/JoyConSwift/LICENSE-JoyConSwift.txt) since it only ships
        // a CocoaPods podspec, not a Package.swift.
        .target(
            name: "JoyConSwift",
            exclude: ["LICENSE-JoyConSwift.txt"]
        ),
        .executableTarget(
            name: "GyroKeyMapper",
            dependencies: ["JoyConSwift"]
        ),
    ]
)
