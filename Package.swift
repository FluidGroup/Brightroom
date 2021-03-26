// swift-tools-version:5.3
import PackageDescription

let package = Package(
  name: "Pixel",  
  platforms: [
    .iOS(.v14)
  ],
  products: [
    .library(name: "PixelEngine", targets: ["PixelEngine"]),
    .library(name: "PixelEditor", targets: ["PixelEditor"]),
  ],
  dependencies: [
    .package(url: "https://github.com/VergeGroup/Verge.git", from: "8.8.0"),
    .package(url: "https://github.com/muukii/TransitionPatch.git", from: "1.0.3")
  ],
  targets: [
    .target(name: "PixelEngine", dependencies: ["Verge"], exclude: ["Info.plist"]),
    .target(name: "PixelEditor", dependencies: ["PixelEngine", "Verge", "TransitionPatch"], exclude: ["Info.plist"]),
  ],
  swiftLanguageVersions: [.v5]
)
