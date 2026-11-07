// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "ScreenRecall",
  platforms: [.macOS("27.0")],
  products: [
    .executable(name: "ScreenRecall", targets: ["ScreenRecall"]),
    .executable(name: "RecallCheck", targets: ["RecallCheck"]),
  ],
  targets: [
    .systemLibrary(name: "CWebP", pkgConfig: "libwebp", providers: [.brew(["webp"])]),
    .target(
      name: "RecallCore", dependencies: ["CWebP"], linkerSettings: [.linkedLibrary("sqlite3")]),
    .executableTarget(name: "ScreenRecall", dependencies: ["RecallCore"]),
    .executableTarget(name: "RecallCheck", dependencies: ["RecallCore"]),
    .testTarget(name: "RecallCoreTests", dependencies: ["RecallCore", "ScreenRecall"]),
  ]
)
