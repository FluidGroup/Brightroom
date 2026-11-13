// Copyright (c) 2026 Hiroshi Kimura (Muukii)

import CoreImage

/// Adjusts local contrast in a developed RGB image using Camera Raw's signed Clarity scale.
///
/// Positive amounts accentuate tonal differences around edges. Negative amounts
/// soften them. The effect also adjusts color width according to the surrounding
/// contrast. It approximates Lightroom Process Version 15.4 on SDR images.
/// A nonzero adjustment requires a finite extent to size its neighborhoods.
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
    return try ClarityRecipe.apply(to: image, amount: amount)
  }

  private static func clamp(_ amount: Double) -> Double {
    amount.isFinite ? min(max(amount, -100), 100) : 0
  }
}
