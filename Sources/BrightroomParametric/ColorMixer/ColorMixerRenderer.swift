//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import CoreImage
import Foundation

/// Evaluates a Color Mixer using the selected algorithm's Metal kernel.
nonisolated enum ColorMixerRenderer {

  /// Returns the same image instance when all eight bands are neutral.
  static func apply(
    to image: CIImage,
    adjustment: ColorMixerAdjustment,
    algorithm: ColorMixerFeature.Algorithm = .oklch
  ) throws -> CIImage {
    guard let plan = ColorMixerRenderPlan(adjustment: adjustment, algorithm: algorithm) else {
      return image
    }
    return try apply(to: image, plan: plan)
  }

  /// Applies an already packed render plan without gamut clipping.
  static func apply(to image: CIImage, plan: ColorMixerRenderPlan) throws -> CIImage {
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
      throw ColorMixerRendererError.cannotApplyKernel
    }
    return output.cropped(to: image.extent)
  }

  private static func vector(_ value: SIMD4<Float>) -> CIVector {
    CIVector(x: CGFloat(value.x), y: CGFloat(value.y), z: CGFloat(value.z), w: CGFloat(value.w))
  }
}

/// Errors raised while loading or evaluating the Color Mixer kernel.
nonisolated enum ColorMixerRendererError: LocalizedError {
  case cannotLoadKernel(String)
  case cannotApplyKernel

  var errorDescription: String? {
    switch self {
    case .cannotLoadKernel(let error): "Brightroom couldn't load its Color Mixer kernel: \(error)"
    case .cannotApplyKernel: "Brightroom couldn't render the Color Mixer."
    }
  }
}

private nonisolated enum ColorMixerKernelStore {
  static func kernel() throws -> CIKernel {
    switch loadedKernel {
    case .success(let kernel): kernel
    case .failure(let error): throw error
    }
  }

  private static let loadedKernel: Result<CIKernel, ColorMixerRendererError> = {
    do {
      let data = try ColorAdjustmentMetalLibrary.data()
      return .success(
        try CIKernel(functionName: "brightroomColorMixer", fromMetalLibraryData: data))
    } catch {
      return .failure(.cannotLoadKernel(String(describing: error)))
    }
  }()
}
