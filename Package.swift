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
  ],
  targets: [
    // SwiftPM compiles the target's `.metal` sources into its default
    // library without a resource declaration. Declaring them as resources
    // makes Tuist's package integration compile each one twice, which Xcode
    // rejects as duplicate tasks.
    .target(
      name: "BrightroomParametric",
      dependencies: ["BrightroomColorAdjustmentKernels"],
      exclude: [
        // Included by the compiled `.metal` sources; not a standalone package
        // input.
        "BrushStampFalloff.metalh"
      ]
    ),
    // General Core Image kernels require different Metal flags from the
    // stitchable and live brush shaders in BrightroomParametric.
    .target(
      name: "BrightroomColorAdjustmentKernels",
      exclude: ["ColorAdjustmentWorkingSpace.metalh"],
      plugins: [
        .plugin(name: "BuildColorAdjustmentKernels")
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
      ]
    ),
    .testTarget(
      name: "BrightroomParametricTests",
      dependencies: ["BrightroomParametric"]
    ),
    // EditingDocument, SourceImage, and the ImageEditor document flows. Hosts
    // BrightroomUI views, so it depends on the whole stack.
    .testTarget(
      name: "BrightroomEngineDocumentTests",
      dependencies: ["BrightroomEngine", "BrightroomUI", "BrightroomParametric"]
    ),
    // Canvas tests: `CanvasNavigation` and the canvas's shared render path
    // (iOS and macOS), and on macOS the AppKit canvas and its SwiftUI hosting.
    .testTarget(
      name: "BrightroomCanvasTests",
      dependencies: ["BrightroomEngine", "BrightroomUI", "BrightroomParametric"]
    ),
    .plugin(
      name: "BuildColorAdjustmentKernels",
      capability: .buildTool()
    ),
  ],
  swiftLanguageModes: [.v6]
)
