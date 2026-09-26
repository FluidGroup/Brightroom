//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import CoreImage
import Foundation

/// An eight-band color adjustment evaluated by the selected algorithm.
///
/// The OKLCh algorithm evaluates extended-linear Display-P3 components. Render the
/// resulting image with a `CIContext` whose working color space is
/// `CGColorSpace.extendedLinearDisplayP3` and whose working format is floating
/// point, such as `CIFormat.RGBAh` or `CIFormat.RGBAf`. The feature does not
/// change the context's color space, clip the gamut, or choose its position
/// relative to other features; the containing pipeline owns that order.
///
/// Constructing the feature compiles its authored values once. Neutral values
/// bypass rendering exactly. The authored adjustment and algorithm are all a
/// host needs to store; constructing the feature again rebuilds the plan.
public nonisolated struct ColorMixerFeature: ImageEffectFeatureType {

  /// The color model and correction semantics used to interpret all eight bands.
  ///
  /// Each case identifies a supported rendering implementation, rather than a
  /// UI presentation. Raw values are stable identifiers a host can store.
  public enum Algorithm: String, CaseIterable, Hashable, Sendable {

    /// Adjusts hue, chroma, and lightness in OKLCh without gamut clipping.
    ///
    /// Adjacent perceptual hue anchors blend with smoothstep weights, and a
    /// low-chroma gate protects neutral pixels.
    /// It does not claim compatibility with Lightroom's Color Mixer.
    case oklch
  }

  /// Stable identity of this Color Mixer node in an editing document.
  public let id: FeatureID

  /// The complete authored eight-band adjustment.
  public let adjustment: ColorMixerAdjustment

  /// The implementation that interprets the authored band corrections.
  public let algorithm: Algorithm

  /// Whether at least one authored correction requires a render pass.
  public let isEnabled: Bool

  private let renderPlan: ColorMixerRenderPlan?

  /// Creates one Color Mixer node and compiles its authored parameters.
  ///
  /// Supply a distinct identifier when a document contains multiple mixers.
  public init(
    id: FeatureID = FeatureID(rawValue: "brightroom.color-mixer"),
    adjustment: ColorMixerAdjustment,
    algorithm: Algorithm = .oklch
  ) {
    self.id = id
    self.adjustment = adjustment
    self.algorithm = algorithm
    renderPlan = ColorMixerRenderPlan(adjustment: adjustment, algorithm: algorithm)
    isEnabled = renderPlan != nil
  }

  /// Evaluates one pass, preserving the exact neutral bypass and input extent.
  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    guard let renderPlan else { return image }
    return try ColorMixerRenderer.apply(to: image, plan: renderPlan)
  }

  /// Compares identity, algorithm, and the normalized values used for rendering.
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id && lhs.algorithm == rhs.algorithm && lhs.renderPlan == rhs.renderPlan
  }
}
