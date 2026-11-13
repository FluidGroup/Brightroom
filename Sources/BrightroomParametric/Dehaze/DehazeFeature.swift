// Copyright (c) 2026 Hiroshi Kimura (Muukii)

import CoreImage

/// Adjusts atmospheric haze in a developed RGB image.
///
/// Pass the signed Camera Raw `Dehaze` amount directly. Positive values remove
/// haze and negative values add it. The effect estimates the brightness of the
/// haze from the image and varies the adjustment with the surrounding colors.
///
/// The response approximates SDR Lightroom Process Version 15.4. It was measured
/// at −100, −50, +9, +50 and +100. Intermediate amounts interpolate between
/// those responses. A nonzero adjustment needs a finite input extent to measure
/// the scene. The output preserves that extent, alpha, and extended-range headroom.
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
    return try DehazeRecipe.apply(to: image, amount: amount)
  }

  private static func clamp(_ amount: Double) -> Double {
    amount.isFinite ? min(max(amount, -100), 100) : 0
  }
}
