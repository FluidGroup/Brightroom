import Foundation
import PackagePlugin

/// Builds the general Core Image kernels as package resources from their sources.
///
/// SwiftPM does not expose Metal compiler flags on a target. These declared build
/// commands preserve the Core Image sampler ABI and rebuild the libraries when
/// a shader or its shared color-space header changes.
@main
struct BuildColorAdjustmentKernels: BuildToolPlugin {

  func createBuildCommands(context: PluginContext, target: any Target) async throws -> [Command] {
    let sources = [
      target.directoryURL.appending(path: "ToneCurveKernels.metal"),
      target.directoryURL.appending(path: "ColorMixerKernels.metal"),
      target.directoryURL.appending(path: "ColorMixerCalibrationKernels.metal"),
      target.directoryURL.appending(path: "ColorGradingKernels.metal"),
      target.directoryURL.appending(path: "PointCurveKernels.metal"),
      target.directoryURL.appending(path: "ClarityKernels.metal"),
      target.directoryURL.appending(path: "TextureKernels.metal"),
      target.directoryURL.appending(path: "DehazeKernels.metal"),
      target.directoryURL.appending(path: "GrainKernels.metal"),
      target.directoryURL.appending(path: "HighlightShadowKernels.metal"),
    ]
    let colorSpaceHeader = target.directoryURL.appending(path: "ColorAdjustmentWorkingSpace.metalh")

    // Plugin output directories may be shared across destination builds. Fixed
    // platform names keep each declared output independent of the active SDK.
    let platforms = [
      (name: "ios", sdk: "iphoneos", target: "air64-apple-ios17.0"),
      (name: "simulator", sdk: "iphonesimulator", target: "air64-apple-ios17.0-simulator"),
      (name: "macos", sdk: "macosx", target: "air64-apple-macos14.0"),
      (name: "catalyst", sdk: "macosx", target: "air64-apple-ios17.0-macabi"),
    ]

    return platforms.map { platform in
      let output = context.pluginWorkDirectoryURL.appending(
        path: "BrightroomColorAdjustments-\(platform.name).metallib"
      )
      return .buildCommand(
        displayName: "Compile Brightroom color adjustment kernels (\(platform.name))",
        executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
        arguments: [
          "--sdk", platform.sdk, "metal",
          "-target", platform.target,
          "-fcikernel",
          "-fmetal-math-mode=fast",
          "-fmetal-math-fp32-functions=fast",
        ] + sources.map(\.path) + ["-o", output.path],
        inputFiles: sources + [colorSpaceHeader],
        outputFiles: [output]
      )
    }
  }
}
