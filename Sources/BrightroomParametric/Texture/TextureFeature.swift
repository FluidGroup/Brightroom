// Copyright (c) 2026 Hiroshi Kimura (Muukii)

import BrightroomColorAdjustmentKernels
import CoreImage

/// Enhances or softens local detail in a developed RGB image.
///
/// Pass the signed Camera Raw `Texture` value directly. Positive amounts
/// increase local contrast and negative amounts soften it. Neighborhoods
/// are measured in full-resolution pixels and scale with the preview.
/// The response was calibrated on Process Version 15.4 SDR exports.
public nonisolated struct TextureFeature: ImageEffect, Equatable, Sendable {

  /// The signed amount from −100 through 100. Zero is neutral.
  public var amount: Double { didSet { amount = Self.clamp(amount) } }

  /// Creates a texture adjustment, clamping the amount and treating nonfinite values as zero.
  public init(amount: Double = 0) {
    self.amount = Self.clamp(amount)
  }

  /// Restores an authored amount, rejecting nonfinite or out-of-range values.
  public init?(validatingAmount amount: Double) {
    guard (-100...100).contains(amount) else { return nil }
    self.amount = amount
  }

  private static func clamp(_ amount: Double) -> Double {
    amount.isFinite ? min(max(amount, -100), 100) : 0
  }

  private struct Kernels {
    let code: CIColorKernel
    let squaredCode: CIColorKernel
    let response: CIColorKernel
  }

  private static let kernels: Result<Kernels, FeatureEvaluationError> = {
    do {
      let library = try ColorAdjustmentMetalLibrary.data()
      return .success(Kernels(
        code: try CIColorKernel(functionName: "brightroomTextureCode", fromMetalLibraryData: library),
        squaredCode: try CIColorKernel(functionName: "brightroomTextureSquare", fromMetalLibraryData: library),
        response: try CIColorKernel(functionName: "brightroomTexture", fromMetalLibraryData: library)))
    } catch {
      return .failure(.kernelUnavailable(name: "brightroomTexture", reason: String(describing: error)))
    }
  }()

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    guard amount != 0, !image.extent.isEmpty else { return image }
    let kernels = try Self.kernels.get()
    let radius = EffectRadius.absolute(12).pixels(in: context, for: image)
    return try ColorAdjustmentKernelSpace.apply(to: image, kernelName: "brightroomTexture") { input in
      // All three branches read the upstream edit. Share it at the input resolution.
      let source = input.insertingIntermediate(cache: true)
      let bounds = input.extent
      guard let field = kernels.code.apply(extent: bounds, arguments: [source]) else {
        throw FeatureEvaluationError.imageCreationFailed("Texture input")
      }
      let code = field.insertingIntermediate(cache: true)
      guard let squared = kernels.squaredCode.apply(extent: bounds, arguments: [code]) else {
        throw FeatureEvaluationError.imageCreationFailed("Texture neighborhood")
      }
      // At a 12-pixel radius the two moments can be averaged on a half-size
      // grid. Sample squared codes before reducing to retain fine contrast.
      let scale: CGFloat = radius >= 6 ? 0.5 : 1
      let down = CGAffineTransform(scaleX: scale, y: scale)
      let reducedBounds = bounds.applying(down)
      func mean(_ field: CIImage) -> CIImage {
        field.clampedToExtent().samplingLinear().transformed(by: down).cropped(to: reducedBounds)
          .clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius * scale])
          .cropped(to: reducedBounds).insertingIntermediate(cache: true)
          .clampedToExtent().samplingLinear().transformed(by: down.inverted()).cropped(to: bounds)
      }
      guard let result = kernels.response.apply(extent: bounds,
        arguments: [source, mean(code), mean(squared), Float(amount)]) else {
        throw FeatureEvaluationError.imageCreationFailed("brightroomTexture")
      }
      return result
    }
  }
}
