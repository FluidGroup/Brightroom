// Copyright (c) 2026 Hiroshi Kimura (Muukii)

import BrightroomColorAdjustmentKernels
import CoreImage

/// Measures a pixel's difference from its surroundings and the local means
/// of the signed and absolute differences. Both guides weight samples by opacity.
nonisolated enum ClarityRecipe {

  private struct Kernels {
    let luminance: CIColorKernel
    let deviation: CIColorKernel
    let response: CIKernel
  }

  private static let kernels: Result<Kernels, FeatureEvaluationError> = {
    do {
      let library = try ColorAdjustmentMetalLibrary.data()
      return .success(Kernels(
        luminance: try CIColorKernel(functionName: "brightroomClarityLuminance", fromMetalLibraryData: library),
        deviation: try CIColorKernel(functionName: "brightroomClarityDeviation", fromMetalLibraryData: library),
        response: try CIKernel(functionName: "brightroomClarity", fromMetalLibraryData: library)))
    } catch {
      return .failure(.kernelUnavailable(name: "brightroomClarity", reason: String(describing: error)))
    }
  }()

  static func apply(to image: CIImage, amount: Double) throws -> CIImage {
    let bounds = image.extent
    guard !bounds.isInfinite, bounds.width.isFinite, bounds.height.isFinite else {
      throw FeatureEvaluationError.imageCreationFailed("Clarity requires a finite input extent")
    }
    let kernels = try kernels.get()
    return try ColorAdjustmentKernelSpace.apply(to: image, kernelName: "brightroomClarity") { input in
      let origin = bounds.origin
      // The full-resolution output and both guide passes reuse the same upstream
      // edit. Share its rendered tiles when building this spatial branch.
      let source = input.insertingIntermediate(cache: true)
      let local = source.transformed(by: .init(translationX: -origin.x, y: -origin.y))
      guard let luminance = kernels.luminance.apply(extent: local.extent, arguments: [local]) else {
        throw FeatureEvaluationError.imageCreationFailed("Clarity luminance")
      }
      let longEdge = max(bounds.width, bounds.height)
      let scale = min(1, 1024 / longEdge)
      let extent = local.extent.applying(.init(scaleX: scale, y: scale))
      let guide = luminance.clampedToExtent().applyingFilter("CILanczosScaleTransform",
        parameters: [kCIInputScaleKey: scale, "inputAspectRatio": 1]).cropped(to: extent)
      func blur(_ field: CIImage) -> CIImage {
        field.clampedToExtent().applyingFilter("CIGaussianBlur",
          parameters: [kCIInputRadiusKey: 8 * longEdge * scale / 1024]).cropped(to: extent)
      }
      let mean = blur(guide).insertingIntermediate(cache: true)
      guard let difference = kernels.deviation.apply(extent: extent, arguments: [guide, mean]) else {
        throw FeatureEvaluationError.imageCreationFailed("Clarity local contrast")
      }
      let energy = blur(difference).insertingIntermediate(cache: true)
      let geometry = CIVector(x: origin.x, y: origin.y, z: scale)
      guard let result = kernels.response.apply(extent: bounds, roiCallback: { index, rect in
        if index == 0 { return rect }
        return rect.offsetBy(dx: -origin.x, dy: -origin.y)
          .applying(.init(scaleX: scale, y: scale)).insetBy(dx: -1, dy: -1)
      }, arguments: [source, mean.clampedToExtent(), energy.clampedToExtent(), geometry, Float(amount)]) else {
        throw FeatureEvaluationError.imageCreationFailed("brightroomClarity")
      }
      return result.cropped(to: bounds)
    }
  }
}
