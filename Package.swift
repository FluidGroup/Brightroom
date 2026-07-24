// swift-tools-version:6.3
import PackageDescription

let package = Package(
  name: "Brightroom",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    .library(name: "BrightroomParametric", targets: ["BrightroomParametric"]),
    .library(name: "BrightroomEngine", targets: ["BrightroomEngine"]),
    .library(name: "BrightroomUI", targets: ["BrightroomUI"]),
  ],
  dependencies: [
    .package(url: "https://github.com/VergeGroup/swift-state-graph", exact: "0.17.0"),
    .package(url: "https://github.com/FluidGroup/TransitionPatch", from: "1.0.3"),
  ],
  targets: [
    .target(
      name: "BrightroomParametric",
      exclude: [
        // Included by the compiled `.metal` sources; not a standalone package
        // input.
        "BrushStampFalloff.metalh"
      ]
    ),
    .target(
      name: "BrightroomEngine",
      dependencies: [
        "BrightroomParametric",
        .product(name: "StateGraph", package: "swift-state-graph"),
      ]
    ),
    .target(
      name: "BrightroomUI",
      dependencies: [
        "BrightroomEngine",
        "BrightroomParametric",
        .product(name: "StateGraph", package: "swift-state-graph"),
        "TransitionPatch",
      ]
    ),
    .testTarget(
      name: "BrightroomParametricTests",
      dependencies: ["BrightroomParametric"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
