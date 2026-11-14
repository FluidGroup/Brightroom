// Copyright (c) 2026 Hiroshi Kimura (Muukii)

/// Selects how Highlights and Shadows respond to developed pixels.
public enum HighlightShadowAlgorithm: Equatable, Sendable {
  /// The original `CIHighlightShadowAdjust` recipe. Existing edits keep this
  /// default, including Core Image's highlight recovery parameter convention.
  case coreImage

  /// A spatial SDR approximation measured from Lightroom Process Version 15.4.
  ///
  /// The response considers several neighborhood sizes and whole-image
  /// luminance statistics. Its calibration uses synthetic scenes and
  /// photographs developed from a common RGB input. Both slider directions
  /// operate on the developed pixels. Strong edits and saturated colors
  /// can differ from Camera Raw.
  case lightroomApproximation
}
