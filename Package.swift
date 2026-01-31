// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "Brightroom",
  platforms: [
    .iOS(.v17)
  ],
  products: [
    .library(name: "BrightroomEngine", targets: ["BrightroomUI"]),
    .library(name: "BrightroomUI", targets: ["BrightroomUI"]),
    .library(name: "BrightroomUIPhotosCrop", targets: ["BrightroomUIPhotosCrop"])
  ],
  dependencies: [
    .package(url: "https://github.com/VergeGroup/swift-state-graph", exact: "0.17.0"),
    .package(url: "https://github.com/FluidGroup/TransitionPatch", from: "1.0.3"),
    .package(url: "https://github.com/FluidGroup/PrecisionLevelSlider", from: "2.1.0"),
  ],
  targets: [
    .target(
      name: "BrightroomEngine",
      dependencies: [
        .product(name: "StateGraph", package: "swift-state-graph"),
      ]
    ),
    .target(
      name: "BrightroomUI",
      dependencies: [
        "BrightroomEngine",
        .product(name: "StateGraph", package: "swift-state-graph"),
        "TransitionPatch",
      ]
    ),
    .target(
      name: "BrightroomUIPhotosCrop",
      dependencies: ["BrightroomUI", "PrecisionLevelSlider"]
    )
  ]
)
