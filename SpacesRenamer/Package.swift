// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "SpacesRenamer",
  platforms: [.macOS("26.0")],
  targets: [
    .target(
      name: "CGSPrivate",
      linkerSettings: [.linkedFramework("CoreGraphics")]
    ),
    .executableTarget(
      name: "SpacesRenamer",
      dependencies: ["CGSPrivate"]
    ),
  ]
)
