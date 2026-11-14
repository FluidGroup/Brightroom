// Copyright (c) 2026 Hiroshi Kimura (Muukii)

import CoreImage

/// Adjusts the dark end of a developed image with a measured tonal response.
///
/// Positive amounts lift blacks; negative amounts deepen them. This is a
/// pointwise SDR approximation measured from Lightroom Process Version 15.4.
/// It does not reproduce image-adaptive behavior. Negative Blacks still shows
/// a mismatch on a uniform midgray validation image.
///
/// The effect preserves alpha and extent. Outside the measured Display-P3 SDR
/// cube it extends the boundary response without clipping the input; this is
/// not a model of Adobe HDR processing. It does not change RAW development.
public nonisolated struct BlacksFeature: ImageEffect, Equatable, Sendable {

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
    return try TonalPointRecipe.apply(to: image, control: .blacks, amount: amount)
  }

  private static func clamp(_ amount: Double) -> Double {
    amount.isFinite ? min(max(amount, -100), 100) : 0
  }
}
