//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import Foundation

extension ColorMixerFeature {

  /// A fixed hue region shared by Color Mixer algorithms.
  ///
  /// Declaration order is render-significant and follows the cyclic sequence
  /// used by the packed Metal parameters. Additions therefore require a render
  /// semantic-version change rather than an insertion into this list.
  public nonisolated enum Band: Int, CaseIterable, Hashable, Identifiable,
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
  public nonisolated struct BandCorrection: Equatable, Sendable {

    /// The supported range shared by Hue, Saturation, and Luminance.
    public static let supportedRange = -100.0...100.0

    /// The hue correction; OKLCh moves toward the previous or next perceptual anchor.
    public var hue: Double { didSet { hue = Self.clamped(hue) } }

    /// The saturation correction; OKLCh scales chroma from zero through twice its value.
    public var saturation: Double { didSet { saturation = Self.clamped(saturation) } }

    /// The luminance correction; OKLCh scales lightness from one half through twice its value.
    public var luminance: Double { didSet { luminance = Self.clamped(luminance) } }

    /// Whether all three authored corrections leave pixels unchanged.
    public var isIdentity: Bool {
      hue == 0 && saturation == 0 && luminance == 0
    }

    /// Creates a band correction and clamps every axis to `-100...100`.
    ///
    /// Clamping does not reject NaN. Use ``init(validatingHue:saturation:luminance:)``
    /// for values that did not come from an editing control.
    public init(hue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
      self.hue = Self.clamped(hue)
      self.saturation = Self.clamped(saturation)
      self.luminance = Self.clamped(luminance)
    }

    /// Restores a band correction without clamping, for values the host stored.
    ///
    /// - Returns: `nil` when any axis is not finite or lies outside `-100...100`.
    public init?(validatingHue hue: Double, saturation: Double, luminance: Double) {
      // The finite closed range also excludes NaN and infinities.
      guard [hue, saturation, luminance].allSatisfy({ Self.supportedRange.contains($0) }) else {
        return nil
      }
      self.init(hue: hue, saturation: saturation, luminance: luminance)
    }

    private static func clamped(_ value: Double) -> Double {
      min(max(value, supportedRange.lowerBound), supportedRange.upperBound)
    }
  }

  /// The complete eight-band Color Mixer correction.
  ///
  /// Fixed stored slots make missing and duplicate bands unrepresentable while
  /// the typed subscript keeps render packing independent of UI collections.
  public nonisolated struct Bands: Equatable, Sendable {

    /// The identity bands used by a new editing session.
    public static let neutral = Bands()

    /// Corrections applied around the red hue anchor.
    public var red: BandCorrection
    /// Corrections applied around the orange hue anchor.
    public var orange: BandCorrection
    /// Corrections applied around the yellow hue anchor.
    public var yellow: BandCorrection
    /// Corrections applied around the green hue anchor.
    public var green: BandCorrection
    /// Corrections applied around the aqua hue anchor.
    public var aqua: BandCorrection
    /// Corrections applied around the blue hue anchor.
    public var blue: BandCorrection
    /// Corrections applied around the purple hue anchor.
    public var purple: BandCorrection
    /// Corrections applied around the magenta hue anchor.
    public var magenta: BandCorrection

    /// Whether every fixed band leaves color unchanged.
    public var isIdentity: Bool {
      Band.allCases.allSatisfy { self[$0].isIdentity }
    }

    /// Creates the complete correction from eight independently authored bands.
    public init(
      red: BandCorrection = .init(),
      orange: BandCorrection = .init(),
      yellow: BandCorrection = .init(),
      green: BandCorrection = .init(),
      aqua: BandCorrection = .init(),
      blue: BandCorrection = .init(),
      purple: BandCorrection = .init(),
      magenta: BandCorrection = .init()
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
    public subscript(_ band: Band) -> BandCorrection {
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
}
