// Copyright (c) 2026 Hiroshi Kimura (Muukii)

import CoreImage

/// Adjusts the bright end of a developed image.
///
/// Positive amounts brighten whites; negative amounts lower them.
/// The standard response preserves alpha, extent, and extended-range components.
public nonisolated struct WhitesFeature: ImageEffect, Equatable, Sendable {

  /// Signed strength from -100 through 100. Zero bypasses the effect exactly.
  public var amount: Double { didSet { amount = Self.clamp(amount) } }

  /// Creates an adjustment, clamping finite amounts and replacing nonfinite
  /// amounts with zero. Use the validating initializer when restoring edits.
  public init(amount: Double = 0) {
    self.amount = Self.clamp(amount)
  }

  /// Restores an amount without silently repairing invalid stored values.
  public init?(validatingAmount amount: Double) {
    guard (-100...100).contains(amount) else { return nil }
    self.init(amount: amount)
  }

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    guard amount != 0 else { return image }
    if let output = try context.adjustmentRendering.apply(self, to: image, context: context) {
      return output
    }
    return try TonalPointRecipe.apply(to: image, control: .whites, amount: amount)
  }

  private static func clamp(_ amount: Double) -> Double {
    amount.isFinite ? min(max(amount, -100), 100) : 0
  }
}
