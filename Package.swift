// swift-tools-version:5.3
import PackageDescription

let package = Package(
  name: "Brightroom",
  platforms: [
    .iOS(.v12)
  ],
  products: [
    .library(name: "BrightroomEngine", targets: ["BrightroomUI"]),
    .library(name: "BrightroomUI", targets: ["BrightroomUI"]),
  ],
  dependencies: [
    .package(url: "https://github.com/VergeGroup/Verge.git", from: "8.8.0"),
    .package(url: "https://github.com/muukii/TransitionPatch.git", from: "1.0.3")
  ],
  targets: [
    .target(name: "BrightroomEngine", dependencies: ["Verge"], exclude: ["Info.plist"]),
    .target(name: "BrightroomUI", dependencies: ["BrightroomEngine", "Verge", "TransitionPatch"], exclude: ["Info.plist"]),
  ],
  swiftLanguageVersions: [.v5]
)
