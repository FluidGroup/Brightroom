// Copyright (c) 2026 Hiroshi Kimura (Muukii)

import CoreImage

/// Adjusts signed highlights and shadows together, in Shadows-then-Highlights order.
public nonisolated struct HighlightsShadowsFeature: ImageEffect, Equatable {

  /// The authored highlight slider amount, from −100 through 100.
  public var highlights: Double

  /// The authored shadow slider amount, from −100 through 100.
  public var shadows: Double

  /// Creates a joint adjustment. Either slider can be used alone.
  ///
  /// Rendering clamps finite values to the slider range and treats each
  /// nonfinite value as zero. Two zero amounts return the original image.
  public init(highlights: Double, shadows: Double) {
    self.highlights = highlights
    self.shadows = shadows
  }

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    let h = highlights.isFinite ? min(100, max(-100, highlights)) : 0
    let s = shadows.isFinite ? min(100, max(-100, shadows)) : 0
    guard h != 0 || s != 0 else {
      return image
    }
    if let output = try context.adjustmentRendering.apply(self, to: image, context: context) {
      return output
    }
    return try body.apply(to: image, context: context.resolvingChainEntry(for: image))
  }

  public var body: some ImageEffect {
    let h = highlights.isFinite ? min(100, max(-100, highlights)) : 0
    let s = shadows.isFinite ? min(100, max(-100, shadows)) : 0
    ShadowsFeature(value: s / 100)
    HighlightsFeature(value: -h / 100)
  }
}
