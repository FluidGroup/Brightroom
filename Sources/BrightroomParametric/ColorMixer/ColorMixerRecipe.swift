//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import BrightroomColorAdjustmentKernels
import CoreImage
import Foundation

/// Evaluates a Color Mixer using the selected algorithm's Metal kernel.
nonisolated enum ColorMixerRecipe {

  /// Returns the same image instance when all eight bands are neutral.
  static func apply(
    to image: CIImage,
    bands: ColorMixerFeature.Bands,
    algorithm: ColorMixerFeature.Algorithm = .oklch
  ) throws -> CIImage {
    guard let plan = ColorMixerRenderPlan(bands: bands, algorithm: algorithm) else {
      return image
    }
    return try apply(to: image, plan: plan)
  }

  /// Applies an already packed render plan without gamut clipping.
  ///
  /// The kernel computes in extended-linear Display-P3 whatever the
  /// rendering context's working space is (`ColorAdjustmentKernelSpace`).
  static func apply(to image: CIImage, plan: ColorMixerRenderPlan) throws -> CIImage {
    try ColorAdjustmentKernelSpace.apply(
      to: image,
      kernelName: ColorMixerKernelStore.name
    ) { image in
      try applyKernel(to: image, plan: plan)
    }
  }

  /// Runs the kernel on the image's working-space values as they are, with
  /// no color-space match. Use `apply(to:plan:)`; tests call this to show
  /// that the match changes nothing in an extended-linear Display-P3 context.
  static func applyKernel(to image: CIImage, plan: ColorMixerRenderPlan) throws -> CIImage {
    let kernel: CIKernel
    switch plan.algorithm {
    case .oklch:
      kernel = try ColorMixerKernelStore.kernel()
    }
    guard
      let output = kernel.apply(
        extent: image.extent,
        roiCallback: { _, rect in rect },
        arguments: [
          image,
          vector(plan.hue0), vector(plan.hue1),
          vector(plan.saturation0), vector(plan.saturation1),
          vector(plan.luminance0), vector(plan.luminance1),
        ]
      )
    else {
      throw FeatureEvaluationError.imageCreationFailed(ColorMixerKernelStore.name)
    }
    return output.cropped(to: image.extent)
  }

  private static func vector(_ value: SIMD4<Float>) -> CIVector {
    CIVector(x: CGFloat(value.x), y: CGFloat(value.y), z: CGFloat(value.z), w: CGFloat(value.w))
  }
}

private nonisolated enum ColorMixerKernelStore {

  static let name = "brightroomColorMixer"

  static func kernel() throws -> CIKernel {
    switch loadedKernel {
    case .success(let kernel): kernel
    case .failure(let error): throw error
    }
  }

  private static let loadedKernel: Result<CIKernel, FeatureEvaluationError> = {
    do {
      let data = try ColorAdjustmentMetalLibrary.data()
      return .success(try CIKernel(functionName: name, fromMetalLibraryData: data))
    } catch {
      return .failure(.kernelUnavailable(name: name, reason: String(describing: error)))
    }
  }()
}
