// Copyright (c) 2026 Hiroshi Kimura (Muukii)

import CoreImage

/// Adjusts local contrast in a developed RGB image.
///
/// Positive amounts accentuate tonal differences around edges; negative amounts
/// soften them. The standard neighborhood scales with the chain-entry extent.
public nonisolated struct ClarityFeature: ImageEffect, Equatable, Sendable {

  /// The signed `Clarity2012` amount, from −100 through 100. Zero is neutral.
  public var amount: Double { didSet { amount = Self.clamp(amount) } }

  /// Creates a local contrast adjustment, clamping the amount and treating nonfinite values as zero.
  public init(amount: Double = 0) {
    self.amount = Self.clamp(amount)
  }

  /// Restores a signed amount, rejecting values outside the finite slider range.
  public init?(validatingAmount amount: Double) {
    guard (-100...100).contains(amount) else { return nil }
    self.init(amount: amount)
  }

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    guard amount != 0, !image.extent.isEmpty else { return image }
    if let output = try context.adjustmentRendering.apply(self, to: image, context: context) {
      return output
    }
    let extent = context.chainEntryExtent(for: image)
    guard !extent.isInfinite, extent.width.isFinite, extent.height.isFinite else {
      throw FeatureEvaluationError.imageCreationFailed("Clarity requires a finite chain-entry extent")
    }
    let radius = EffectRadius.proportional(20).pixels(in: context, for: image)
    return try DetailRecipe.apply(to: image, amount: amount, radius: radius)
  }

  private static func clamp(_ amount: Double) -> Double {
    amount.isFinite ? min(max(amount, -100), 100) : 0
  }
}
