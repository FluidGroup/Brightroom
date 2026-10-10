//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import CoreGraphics
import CoreImage
import Foundation

/// The radius of a neighborhood effect, such as a blur, and its unit.
///
/// `GaussianBlurFeature`, `SharpenFeature`, and `UnsharpMaskFeature` use it,
/// each passing the resolved radius to Core Image as `inputRadius`. On a
/// 4000×3000 chain entry, whose diagonal is 5000 px, `.proportional(100)` is
/// 250 px and `.proportional(1)` is 2.5 px.
public enum EffectRadius: Equatable, Sendable {

  /// A radius in pixels of the full-resolution chain entry, the source an
  /// export renders.
  ///
  /// It does not scale with the image's size: on a 4000×3000 and a
  /// 1000×750 source, `.absolute(10)` is 10 px. Brightroom's canvas, which
  /// previews over a downsampled copy of the source, scales it by the
  /// downsample factor, so the preview matches the export.
  case absolute(Double)

  /// A slider value where 100 is a radius of one twentieth of the image
  /// diagonal, scaling linearly. It resolves against the render pass's
  /// chain-entry extent (see `FeatureEvaluationContext.chainEntryExtent`),
  /// so a mid-chain crop never re-bases it.
  case proportional(Double)
}

extension EffectRadius {

  /// Creates an absolute radius, or returns `nil` when `pixels` is negative
  /// or not finite.
  ///
  /// The cases accept any number. Restore a stored radius with this
  /// initializer or ``init(validatingProportional:)``, and reject what they
  /// reject.
  public init?(validatingAbsolute pixels: Double) {
    guard pixels.isFinite, pixels >= 0 else {
      return nil
    }
    self = .absolute(pixels)
  }

  /// Creates a proportional radius, or returns `nil` when `value` is
  /// negative or not finite.
  public init?(validatingProportional value: Double) {
    guard value.isFinite, value >= 0 else {
      return nil
    }
    self = .proportional(value)
  }
}

extension EffectRadius {

  /// The radius in pixels of the current render pass, for an effect
  /// evaluating `image` in `context`.
  ///
  /// `.proportional` resolves against
  /// `context.chainEntryExtent(for: image)`; `.absolute` is scaled by
  /// `context.renderScale`.
  func pixels(in context: FeatureEvaluationContext, for image: CIImage) -> Double {
    switch self {
    case let .absolute(pixels):
      pixels * context.renderScale
    case let .proportional(value):
      RadiusCalculator.radius(
        value: value,
        max: FilterConstants.gaussianBlurSliderMax,
        imageExtent: context.chainEntryExtent(for: image)
      )
    }
  }
}
