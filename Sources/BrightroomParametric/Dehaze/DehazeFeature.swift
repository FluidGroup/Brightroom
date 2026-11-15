// Copyright (c) 2026 Hiroshi Kimura (Muukii)

import CoreImage

/// Adjusts atmospheric haze in a developed RGB image.
///
/// Positive amounts increase contrast and color intensity; negative amounts reduce them.
public nonisolated struct DehazeFeature: ImageEffect, Equatable, Sendable {

  /// Signed strength from −100 through 100. Zero returns the input image itself.
  public var amount: Double { didSet { amount = Self.clamp(amount) } }

  /// Creates an adjustment, clamping out-of-range amounts and treating nonfinite values as zero.
  public init(amount: Double = 0) {
    self.amount = Self.clamp(amount)
  }

  /// Restores an authored amount, rejecting nonfinite and out-of-range values.
  public init?(validatingAmount amount: Double) {
    guard (-100...100).contains(amount) else { return nil }
    self.init(amount: amount)
  }

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    guard amount != 0, !image.extent.isEmpty else { return image }
    if let output = try context.adjustmentRendering.apply(self, to: image, context: context) {
      return output
    }
    return try DehazeRecipe.apply(to: image, amount: amount)
  }

  private static func clamp(_ amount: Double) -> Double {
    amount.isFinite ? min(max(amount, -100), 100) : 0
  }
}
