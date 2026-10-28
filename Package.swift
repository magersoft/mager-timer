// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "MagerTimer",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "TimerCore", targets: ["TimerCore"]),
    .executable(name: "MagerTimer", targets: ["MagerTimer"]),
  ],
  targets: [
    .target(name: "TimerCore"),
    .executableTarget(
      name: "MagerTimer",
      dependencies: ["TimerCore"],
      swiftSettings: [.defaultIsolation(MainActor.self)]
    ),
    .testTarget(
      name: "TimerCoreTests",
      dependencies: ["TimerCore"],
      resources: [.copy("Fixtures")]
    ),
  ]
)
