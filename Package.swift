// swift-tools-version:5.3
import PackageDescription

let package = Package(
  name: "Brightroom",
  platforms: [
    .iOS(.v13)
  ],
  products: [
    .library(name: "BrightroomEngine", targets: ["BrightroomUI"]),
    .library(name: "BrightroomUI", targets: ["BrightroomUI"]),
  ],
  dependencies: [
    .package(name: "Verge", url: "https://github.com/VergeGroup/Verge.git", from: "11.0.0-beta.5"),
    .package(url: "https://github.com/FluidGroup/TransitionPatch.git", from: "1.0.3")
  ],
  targets: [
    .target(
      name: "BrightroomEngine",
      dependencies: ["Verge"],
      exclude: ["Info.plist"]
    ),      
    .target(
      name: "BrightroomUI",
      dependencies: ["BrightroomEngine", "Verge", "TransitionPatch"],
      exclude: ["Info.plist"],
      swiftSettings: [.define("SWIFT_PACKAGE_MANAGER")]
    )
  ],
  swiftLanguageVersions: [.v5]
)
