// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "JupiterFlash",
    platforms: [.macOS(.v13)],
    targets: [
        // All disk / ISO / flashing logic (no UI).
        .target(name: "JupiterFlashCore"),
        // The SwiftUI app.
        .executableTarget(name: "JupiterFlash", dependencies: ["JupiterFlashCore"]),
        // Small command-line front end, handy for scripting and testing.
        .executableTarget(name: "jupiterflash-cli", dependencies: ["JupiterFlashCore"]),
    ]
)
