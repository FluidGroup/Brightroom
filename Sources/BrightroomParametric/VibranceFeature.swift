// Copyright (c) 2026 Hiroshi Kimura (Muukii)

import CoreImage

/// Selectively adjusts saturation while preserving skin tones.
public nonisolated struct VibranceFeature: ImageEffect, Equatable, Sendable {

  /// The signed amount from −100 through 100. Zero returns the input image itself.
  public var amount: Double { didSet { amount = Self.clamp(amount) } }

  public init(amount: Double = 0) {
    self.amount = Self.clamp(amount)
  }

  /// Restores an authored amount, rejecting nonfinite or out-of-range values.
  public init?(validatingAmount amount: Double) {
    guard (-100...100).contains(amount) else { return nil }
    self.amount = amount
  }

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    guard amount != 0, !image.extent.isEmpty else { return image }
    if let output = try context.adjustmentRendering.apply(self, to: image, context: context) {
      return output
    }
    return image.applyingFilter("CIVibrance", parameters: ["inputAmount": amount / 100])
      .cropped(to: image.extent)
  }

  private static func clamp(_ amount: Double) -> Double {
    amount.isFinite ? min(max(amount, -100), 100) : 0
  }
}
