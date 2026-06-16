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
      resources: [
        // Runtime-compiled Core Image kernels; see ParametricKernelRegistry.
        // Named `.metal.txt` (not `.metal`) so SwiftPM/Xcode ship it as a copied
        // resource instead of build-compiling it into a metallib — the kernels
        // reference `brushStampAlpha`, which is injected at runtime and is not
        // present at build time (build-time Metal compilation would fail).
        .copy("ParametricKernels.metal.txt")
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
  ],  
  swiftLanguageModes: [.v6]
)
