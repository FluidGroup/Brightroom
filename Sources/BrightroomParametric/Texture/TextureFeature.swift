// Copyright (c) 2026 Hiroshi Kimura (Muukii)

import CoreImage

/// Enhances or softens local detail in a developed RGB image.
///
/// Positive amounts increase local contrast; negative amounts soften it.
/// The standard neighborhood uses full-resolution pixels and scales with the preview.
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

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    guard amount != 0, !image.extent.isEmpty else { return image }
    if let output = try context.adjustmentRendering.apply(self, to: image, context: context) {
      return output
    }
    let radius = EffectRadius.absolute(12).pixels(in: context, for: image)
    return try DetailRecipe.apply(to: image, amount: amount, radius: radius)
  }
}
