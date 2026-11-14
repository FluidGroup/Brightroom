// Copyright (c) 2026 Hiroshi Kimura (Muukii)

import CoreImage
import Foundation

/// Tints shadows, midtones, highlights, and the whole image independently.
///
/// Hue is an absolute angle, saturation is the strength of the tint, and
/// luminance changes the selected tonal range. A hue with zero saturation
/// does not tint pixels. Blending and balance affect the three tonal ranges;
/// they do not affect the global correction.
///
/// The experimental SDR response is calibrated against Camera Raw adjustments
/// over a common developed RGB input. Global closely matches the measured cases;
/// some shadow/highlight hues still differ substantially. This is not an Adobe
/// compatible preset renderer and does not reproduce Adobe's RAW development or
/// camera profiles. See `docs/color-grading.md` for measured compatibility limits.
/// Rendering uses linear ProPhoto RGB channel curves, matched through
/// extended-linear Display-P3 independently of the context's working space.
/// Alpha and the input extent are preserved. Values outside the calibrated
/// 0...1 range continue with unit slope instead of being clipped.
public nonisolated struct ColorGradingFeature: ImageEffect, Equatable, Sendable {

  /// One independently editable tonal range.
  public enum Range: String, CaseIterable, Identifiable, Sendable {
    case shadows, midtones, highlights, global

    public var id: Self { self }
  }

  /// The tint and luminance adjustment for one range.
  public struct Correction: Equatable, Sendable {

    /// Absolute hue in degrees, from 0 through 360 (both endpoints are red).
    public var hue: Double { didSet { hue = Self.clamp(hue, to: 0...360) } }
    /// Tint strength, from 0 (no tint) through 100.
    public var saturation: Double { didSet { saturation = Self.clamp(saturation, to: 0...100) } }
    /// Tonal brightness adjustment, from -100 through 100; zero is neutral.
    public var luminance: Double { didSet { luminance = Self.clamp(luminance, to: -100...100) } }

    /// Whether this correction leaves pixels unchanged, regardless of hue.
    public var isIdentity: Bool { saturation == 0 && luminance == 0 }

    /// Creates a correction, clamping values to their supported ranges.
    /// Nonfinite values become zero. Use the validating initializer to reject
    /// malformed values when restoring a host's stored edit.
    public init(hue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
      self.hue = Self.clamp(hue, to: 0...360)
      self.saturation = Self.clamp(saturation, to: 0...100)
      self.luminance = Self.clamp(luminance, to: -100...100)
    }

    /// Restores authored values without silently repairing invalid input.
    public init?(validatingHue hue: Double, saturation: Double, luminance: Double) {
      guard (0...360).contains(hue), (0...100).contains(saturation),
        (-100...100).contains(luminance) else { return nil }
      self.init(hue: hue, saturation: saturation, luminance: luminance)
    }

    fileprivate static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
      value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : 0
    }
  }

  /// The correction concentrated in dark tones.
  public var shadows: Correction
  /// The correction concentrated in middle tones.
  public var midtones: Correction
  /// The correction concentrated in light tones.
  public var highlights: Correction
  /// The correction applied across the whole tonal range.
  public var global: Correction

  /// Overlap between the three tonal ranges, from 0 through 100; defaults to 50.
  public var blending: Double { didSet { blending = Correction.clamp(blending, to: 0...100) } }
  /// Distribution toward shadows (-100) or highlights (+100); defaults to zero.
  public var balance: Double { didSet { balance = Correction.clamp(balance, to: -100...100) } }

  /// Whether rendering can return the input image itself.
  public var isIdentity: Bool {
    Range.allCases.allSatisfy { self[$0].isIdentity }
  }

  /// Creates a grading adjustment. Omitted corrections are neutral.
  public init(
    shadows: Correction = .init(), midtones: Correction = .init(),
    highlights: Correction = .init(), global: Correction = .init(),
    blending: Double = 50, balance: Double = 0
  ) {
    self.shadows = shadows
    self.midtones = midtones
    self.highlights = highlights
    self.global = global
    self.blending = Correction.clamp(blending, to: 0...100)
    self.balance = Correction.clamp(balance, to: -100...100)
  }

  /// Restores a grading adjustment, rejecting invalid blending or balance.
  public init?(
    validatingShadows shadows: Correction, midtones: Correction,
    highlights: Correction, global: Correction, blending: Double, balance: Double
  ) {
    guard (0...100).contains(blending), (-100...100).contains(balance) else { return nil }
    self.init(shadows: shadows, midtones: midtones, highlights: highlights,
      global: global, blending: blending, balance: balance)
  }

  /// Accesses the stored correction for one range without changing the others.
  public subscript(range: Range) -> Correction {
    get {
      switch range {
      case .shadows: shadows
      case .midtones: midtones
      case .highlights: highlights
      case .global: global
      }
    }
    set {
      switch range {
      case .shadows: shadows = newValue
      case .midtones: midtones = newValue
      case .highlights: highlights = newValue
      case .global: global = newValue
      }
    }
  }

  /// Evaluates the grading curves, or bypasses a neutral adjustment exactly.
  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    guard !isIdentity else { return image }
    return try ColorGradingRecipe.apply(to: image, grading: self)
  }
}
