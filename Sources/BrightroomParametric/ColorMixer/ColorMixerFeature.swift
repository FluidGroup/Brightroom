//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import CoreImage
import Foundation

/// An eight-band color correction evaluated by the selected algorithm.
///
/// The OKLCh algorithm evaluates extended-linear Display-P3 components. Render the
/// resulting image with a `CIContext` whose working color space is
/// `CGColorSpace.extendedLinearDisplayP3` and whose working format is floating
/// point, such as `CIFormat.RGBAh` or `CIFormat.RGBAf`. The feature does not
/// change the context's color space, clip the gamut, or choose its position
/// relative to other features; the containing pipeline owns that order.
///
/// Constructing the feature compiles its authored values once. Neutral values
/// bypass rendering exactly. The authored bands and algorithm are all a
/// host needs to store; constructing the feature again rebuilds the plan.
///
/// Equality compares the authored `bands` and `algorithm` exactly. The
/// derived render plan, which rounds values to Float32, does not take part. To
/// ask whether two mixers render the same, compare their
/// `ColorMixerFeature.RenderKey(activeBands:algorithm:)`.
public nonisolated struct ColorMixerFeature: ImageEffect, Equatable {

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

  /// The complete authored eight-band correction.
  public let bands: Bands

  /// The implementation that interprets the authored band corrections.
  public let algorithm: Algorithm

  private let renderPlan: ColorMixerRenderPlan?

  /// Creates one Color Mixer node and compiles its authored parameters.
  public init(
    bands: Bands,
    algorithm: Algorithm = .oklch
  ) {
    self.bands = bands
    self.algorithm = algorithm
    renderPlan = ColorMixerRenderPlan(bands: bands, algorithm: algorithm)
  }

  /// Evaluates one pass, preserving the exact neutral bypass and input extent.
  ///
  /// Identity bands (`bands.isIdentity`) return `image` itself.
  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    guard let renderPlan else { return image }
    return try ColorMixerRenderer.apply(to: image, plan: renderPlan)
  }

  /// Compares the authored members; the derived render plan does not take part.
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.bands == rhs.bands && lhs.algorithm == rhs.algorithm
  }
}
