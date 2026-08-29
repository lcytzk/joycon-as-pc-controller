// swift-tools-version:5.9
import PackageDescription

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
