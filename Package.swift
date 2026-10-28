// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "MagerMotivate",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "MotivateCore", targets: ["MotivateCore"]),
    .executable(name: "MagerMotivate", targets: ["MagerMotivate"]),
  ],
  targets: [
    .target(name: "MotivateCore"),
    .executableTarget(
      name: "MagerMotivate",
      dependencies: ["MotivateCore"],
      swiftSettings: [.defaultIsolation(MainActor.self)]
    ),
    .testTarget(
      name: "MotivateCoreTests",
      dependencies: ["MotivateCore"],
      resources: [.copy("Fixtures")]
    ),
  ]
)
