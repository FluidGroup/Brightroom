// swift-tools-version:6.3
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
    .package(url: "https://github.com/VergeGroup/Verge", from: "14.0.0"),
    .package(url: "https://github.com/FluidGroup/TransitionPatch", from: "1.0.3"),
    .package(url: "https://github.com/FluidGroup/PrecisionLevelSlider", from: "3.0.0"),
  ],
  targets: [
    .target(
      name: "BrightroomEngine",
      dependencies: ["Verge"]
    ),
    .target(
      name: "BrightroomUI",
      dependencies: ["BrightroomEngine", "Verge", "TransitionPatch"]
    ),
    .target(
      name: "BrightroomUIPhotosCrop",
      dependencies: ["BrightroomUI", "PrecisionLevelSlider"]
    )
  ],
  swiftLanguageModes: [.v5],
)
