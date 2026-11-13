// Copyright (c) 2026 Hiroshi Kimura (Muukii)

/// Adjusts Highlights and Shadows together on a developed RGB image.
///
/// Pass the signed XMP `Highlights2012` and `Shadows2012` values. When reducing
/// highlights and lifting shadows together, the measured response corresponds
/// to weaker individual adjustments. Below the measured −35/+42 pair, the
/// weaker slider contributes less as the other slider grows. The low-strength
/// response was checked at −11/+30. Other sign combinations compose the
/// individual spatial adjustments, in Shadows-then-Highlights order.
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

  public var body: some ImageEffect {
    let h = highlights.isFinite ? min(100, max(-100, highlights)) : 0
    let s = shadows.isFinite ? min(100, max(-100, shadows)) : 0
    let compressesRange = h < 0 && s > 0
    let shadowAmount = compressesRange
      ? Self.effectiveMagnitude(s, anchor: 42, opposing: -h, attenuation: 0.004924) : s
    let highlightAmount = compressesRange
      ? -Self.effectiveMagnitude(-h, anchor: 35, opposing: s, attenuation: 0.029549) : h
    ShadowsFeature(lightroomAmount: shadowAmount)
    HighlightsFeature(lightroomAmount: highlightAmount)
  }

  // The −35/+42 export anchors both stages. Below its measured strength,
  // the opposing slider competes with the magnitude of this slider. At and
  // above the anchor, retain the attenuation measured by the solo sweeps
  // and the sequential shadow-lift fit.
  private static func effectiveMagnitude(_ amount: Double, anchor: Double, opposing: Double, attenuation: Double) -> Double {
    let fraction = min(1, amount / anchor)
    guard fraction > 0 else { return 0 }
    return amount * (fraction / (fraction + attenuation * opposing))
  }
}
