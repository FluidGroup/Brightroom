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
/// bypass rendering exactly, and persistence stores identity, algorithm, and
/// authored parameters so decoding reconstructs the selected render plan.
public nonisolated struct ColorMixerFeature: ImageEffectFeatureType, PersistableFeature {

  /// The color model and correction semantics used to interpret all eight bands.
  ///
  /// Each case identifies a supported rendering implementation, rather than a
  /// UI presentation. Raw values are stable identifiers in saved documents.
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

  /// The registered document type shared by all Color Mixer algorithms.
  public static let featureTypeKey: FeatureTypeKey = "brightroom.effect.color-mixer"

  /// Version 2 stores the algorithm; version 1 implicitly used OKLCh.
  public static let schemaVersion = 2

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

  /// Restores authored values and derives the enabled state and render plan.
  ///
  /// Invalid or nonfinite axis values are rejected instead of allowing decoding
  /// to bypass the runtime adjustment's range invariants.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let identifier = try container.decode(String.self, forKey: .algorithm)
    guard let algorithm = Algorithm(rawValue: identifier) else {
      throw DecodingError.dataCorruptedError(
        forKey: .algorithm,
        in: container,
        debugDescription: "Unsupported Color Mixer algorithm: \(identifier)."
      )
    }
    self.init(
      id: try container.decode(FeatureID.self, forKey: .id),
      adjustment: try container.decode(StoredAdjustment.self, forKey: .adjustment).value,
      algorithm: algorithm
    )
  }

  /// Migrates the original mixer to OKLCh without changing its authored values.
  public static func decodeParameters(from decoder: Decoder, version: Int) throws -> Self {
    switch version {
    case 2:
      return try Self(from: decoder)
    case 1:
      let parameters = try V1Parameters(from: decoder)
      return Self(id: parameters.id, adjustment: parameters.adjustment.value, algorithm: .oklch)
    default:
      throw ParametricDocumentCodecError.unsupportedSchemaVersion(featureTypeKey, version: version)
    }
  }

  /// Stores the selected algorithm alongside identity and authored values.
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(StoredAdjustment(adjustment), forKey: .adjustment)
    try container.encode(algorithm.rawValue, forKey: .algorithm)
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case adjustment
    case algorithm
  }

  /// The original document shape, whose rendering semantics were always OKLCh.
  private struct V1Parameters: Decodable {
    let id: FeatureID
    let adjustment: StoredAdjustment
  }
}

/// The persisted fixed-band shape, independent of render packing and resources.
private struct StoredAdjustment: Codable {

  let red: StoredBand
  let orange: StoredBand
  let yellow: StoredBand
  let green: StoredBand
  let aqua: StoredBand
  let blue: StoredBand
  let purple: StoredBand
  let magenta: StoredBand

  init(_ value: ColorMixerAdjustment) {
    red = StoredBand(value.red)
    orange = StoredBand(value.orange)
    yellow = StoredBand(value.yellow)
    green = StoredBand(value.green)
    aqua = StoredBand(value.aqua)
    blue = StoredBand(value.blue)
    purple = StoredBand(value.purple)
    magenta = StoredBand(value.magenta)
  }

  var value: ColorMixerAdjustment {
    .init(
      red: red.value,
      orange: orange.value,
      yellow: yellow.value,
      green: green.value,
      aqua: aqua.value,
      blue: blue.value,
      purple: purple.value,
      magenta: magenta.value
    )
  }
}

/// Validates the persisted axes before constructing a runtime band adjustment.
private struct StoredBand: Codable {

  let hue: Double
  let saturation: Double
  let luminance: Double

  init(_ value: ColorMixerBandAdjustment) {
    hue = value.hue
    saturation = value.saturation
    luminance = value.luminance
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    hue = try Self.decodeAxis(.hue, from: container)
    saturation = try Self.decodeAxis(.saturation, from: container)
    luminance = try Self.decodeAxis(.luminance, from: container)
  }

  var value: ColorMixerBandAdjustment {
    .init(hue: hue, saturation: saturation, luminance: luminance)
  }

  private enum CodingKeys: String, CodingKey {
    case hue
    case saturation
    case luminance
  }

  private static func decodeAxis(
    _ key: CodingKeys,
    from container: KeyedDecodingContainer<CodingKeys>
  ) throws -> Double {
    let value = try container.decode(Double.self, forKey: key)
    guard value.isFinite, ColorMixerBandAdjustment.supportedRange.contains(value) else {
      throw DecodingError.dataCorruptedError(
        forKey: key,
        in: container,
        debugDescription: "Color Mixer axes must be finite values in -100...100."
      )
    }
    return value
  }
}
