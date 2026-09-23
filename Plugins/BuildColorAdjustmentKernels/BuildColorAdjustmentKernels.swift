import Foundation
import PackagePlugin

/// Builds the general Core Image kernels as package resources from their sources.
///
/// SwiftPM does not expose Metal compiler flags on a target. These declared build
/// commands preserve the Core Image sampler ABI and rebuild when either shader
/// changes, without compiling source at runtime.
@main
struct BuildColorAdjustmentKernels: BuildToolPlugin {

  func createBuildCommands(context: PluginContext, target: any Target) async throws -> [Command] {
    let sources = [
      target.directoryURL.appending(path: "ToneCurveKernels.metal"),
      target.directoryURL.appending(path: "ColorMixerKernels.metal"),
    ]

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
        inputFiles: sources,
        outputFiles: [output]
      )
    }
  }
}
