//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import Foundation

/// A fixed hue region shared by Color Mixer algorithms.
///
/// Declaration order is render-significant and follows the cyclic sequence
/// used by the packed Metal parameters. Additions therefore require a render
/// semantic-version change rather than an insertion into this list.
public nonisolated enum ColorMixerBand: Int, CaseIterable, Hashable, Identifiable,
  Sendable
{
  case red
  case orange
  case yellow
  case green
  case aqua
  case blue
  case purple
  case magenta

  /// Stable control identity matching the render-significant band slot.
  public var id: Self { self }
}

/// Corrections interpreted by a Color Mixer feature's selected algorithm.
public nonisolated struct ColorMixerBandAdjustment: Equatable, Sendable {

  /// The supported range shared by Hue, Saturation, and Luminance.
  public static let supportedRange = -100.0...100.0

  /// The hue correction; OKLCh moves toward the previous or next perceptual anchor.
  public var hue: Double { didSet { hue = Self.clamped(hue) } }

  /// The saturation correction; OKLCh scales chroma from zero through twice its value.
  public var saturation: Double { didSet { saturation = Self.clamped(saturation) } }

  /// The luminance correction; OKLCh scales lightness from one half through twice its value.
  public var luminance: Double { didSet { luminance = Self.clamped(luminance) } }

  /// Whether all three authored corrections leave pixels unchanged.
  public var isNeutral: Bool {
    hue == 0 && saturation == 0 && luminance == 0
  }

  /// Creates a band adjustment and clamps every axis to `-100...100`.
  public init(hue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
    self.hue = Self.clamped(hue)
    self.saturation = Self.clamped(saturation)
    self.luminance = Self.clamped(luminance)
  }

  private static func clamped(_ value: Double) -> Double {
    min(max(value, supportedRange.lowerBound), supportedRange.upperBound)
  }
}

/// The complete eight-band Color Mixer adjustment.
///
/// Fixed stored slots make missing and duplicate bands unrepresentable while
/// the typed subscript keeps render packing independent of UI collections.
public nonisolated struct ColorMixerAdjustment: Equatable, Sendable {

  /// The identity adjustment used by a new editing session.
  public static let neutral = ColorMixerAdjustment()

  /// Corrections applied around the red hue anchor.
  public var red: ColorMixerBandAdjustment
  /// Corrections applied around the orange hue anchor.
  public var orange: ColorMixerBandAdjustment
  /// Corrections applied around the yellow hue anchor.
  public var yellow: ColorMixerBandAdjustment
  /// Corrections applied around the green hue anchor.
  public var green: ColorMixerBandAdjustment
  /// Corrections applied around the aqua hue anchor.
  public var aqua: ColorMixerBandAdjustment
  /// Corrections applied around the blue hue anchor.
  public var blue: ColorMixerBandAdjustment
  /// Corrections applied around the purple hue anchor.
  public var purple: ColorMixerBandAdjustment
  /// Corrections applied around the magenta hue anchor.
  public var magenta: ColorMixerBandAdjustment

  /// Whether every fixed band leaves color unchanged.
  public var isNeutral: Bool {
    ColorMixerBand.allCases.allSatisfy { self[$0].isNeutral }
  }

  /// Creates the complete adjustment from eight independently authored bands.
  public init(
    red: ColorMixerBandAdjustment = .init(),
    orange: ColorMixerBandAdjustment = .init(),
    yellow: ColorMixerBandAdjustment = .init(),
    green: ColorMixerBandAdjustment = .init(),
    aqua: ColorMixerBandAdjustment = .init(),
    blue: ColorMixerBandAdjustment = .init(),
    purple: ColorMixerBandAdjustment = .init(),
    magenta: ColorMixerBandAdjustment = .init()
  ) {
    self.red = red
    self.orange = orange
    self.yellow = yellow
    self.green = green
    self.aqua = aqua
    self.blue = blue
    self.purple = purple
    self.magenta = magenta
  }

  /// Accesses the one and only stored value for a band.
  public subscript(_ band: ColorMixerBand) -> ColorMixerBandAdjustment {
    get {
      switch band {
      case .red: red
      case .orange: orange
      case .yellow: yellow
      case .green: green
      case .aqua: aqua
      case .blue: blue
      case .purple: purple
      case .magenta: magenta
      }
    }
    set {
      switch band {
      case .red: red = newValue
      case .orange: orange = newValue
      case .yellow: yellow = newValue
      case .green: green = newValue
      case .aqua: aqua = newValue
      case .blue: blue = newValue
      case .purple: purple = newValue
      case .magenta: magenta = newValue
      }
    }
  }
}
