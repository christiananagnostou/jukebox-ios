// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "JukeboxCore", platforms: [.macOS("15.0"), .iOS("27.0")],
  products: [.library(name: "JukeboxCore", targets: ["JukeboxCore"])],
  targets: [
    .target(name: "JukeboxCore"),
    .testTarget(
      name: "JukeboxCoreTests", dependencies: ["JukeboxCore"], resources: [.copy("Fixtures")]),
  ])
