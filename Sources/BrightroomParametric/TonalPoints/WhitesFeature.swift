// Copyright (c) 2026 Hiroshi Kimura (Muukii)

import CoreImage

/// Adjusts the bright end of a developed image with a measured tonal response.
///
/// Positive amounts brighten whites and negative amounts lower them. The SDR
/// response was measured from Lightroom Process Version 15.4. Positive amounts
/// adapt to the luminance distribution and fine-scale contrast of the finite input.
/// From +25, the measured changes of the two outer color channels in linear
/// ProPhoto RGB preserve each input color's hue as whites brighten.
/// Above +75, the peak channel can move toward the white point measured on gray fields.
/// The response of dark photographs with sparse highlights is still under investigation.
///
/// The effect preserves alpha and extent. Outside the measured Display-P3 SDR
/// cube it extends the boundary response without clipping the input; this is
/// not a model of Adobe HDR processing. It does not change RAW development.
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
    return try TonalPointRecipe.apply(to: image, control: .whites, amount: amount)
  }

  private static func clamp(_ amount: Double) -> Double {
    amount.isFinite ? min(max(amount, -100), 100) : 0
  }
}
