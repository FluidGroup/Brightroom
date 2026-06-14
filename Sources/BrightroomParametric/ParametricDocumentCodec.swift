//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import Foundation

// The persistence boundary of the parametric document.
//
// The runtime document is a Swift-native value tree and is not a text
// document. Serialization goes through `ParametricDocumentCodec`, which owns
// a type registry in the `UICollectionView.register(_:forCellWithReuseIdentifier:)`
// shape: the host registers (type key → params type) pairs; decode resolves
// keys once and produces typed values directly from the document stream.
// There is no intermediate JSON representation; an unregistered key on decode
// is an error, and schema migration is typed decoding of old versions.

/// A serialized identifier for a persistable feature type.
public struct FeatureTypeKey: Hashable, Codable, Sendable, RawRepresentable,
  ExpressibleByStringLiteral
{

  public var rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(stringLiteral value: String) {
    self.rawValue = value
  }
}

/// A feature that can be persisted by `ParametricDocumentCodec`.
///
/// Conforming types encode their parameters with their own `Codable`
/// implementation and decode old schema versions by declaring the old shape
/// as a private `Decodable` struct and converting — migration is typed and
/// compiler-checked.
public protocol PersistableFeature: Feature, Codable {

  /// The serialized identifier resolved through the codec's registrations.
  static var featureTypeKey: FeatureTypeKey { get }

  /// The schema version written by `Codable` encoding.
  static var schemaVersion: Int { get }

  /// Decodes parameters that were written with the given schema version.
  static func decodeParameters(from decoder: Decoder, version: Int) throws -> Self
}

extension PersistableFeature {

  public static var schemaVersion: Int { 1 }

  public static func decodeParameters(from decoder: Decoder, version: Int) throws -> Self {
    guard version == schemaVersion else {
      throw ParametricDocumentCodecError.unsupportedSchemaVersion(
        featureTypeKey,
        version: version
      )
    }
    return try Self(from: decoder)
  }
}

/// Errors thrown by the document codec.
public enum ParametricDocumentCodecError: Error, Equatable, Sendable {

  /// The document references a feature type key that has not been registered.
  case unregisteredFeatureType(FeatureTypeKey)

  /// The document stores a schema version the type cannot decode.
  case unsupportedSchemaVersion(FeatureTypeKey, version: Int)

  /// The runtime document contains a feature that does not conform to
  /// `PersistableFeature`.
  case notPersistable(typeName: String)

  /// Coding ran without a codec; use `ParametricDocumentCodec`.
  case missingRegistry

  /// The document's structural format version is not supported by this
  /// library version.
  case unsupportedDocumentFormatVersion(Int)
}

/// The registered (type key → params type) pairs used at the persistence
/// boundary. Registration captures capability-typed decode functions so
/// decoded values come back as the correct existential.
public struct ParametricFeatureTypeRegistry: Sendable {

  private var imageEffectDecoders:
    [FeatureTypeKey: @Sendable (Decoder, Int) throws -> any ImageEffectFeatureType] = [:]
  private var domainDecoders:
    [FeatureTypeKey: @Sendable (Decoder, Int) throws -> any DomainFeatureType] = [:]

  public init() {}

  /// Registers an image-effect params type for persistence.
  ///
  /// Registering the same `featureTypeKey` again replaces the earlier
  /// registration (last wins), mirroring `UICollectionView.register`.
  public mutating func register<T: PersistableFeature & ImageEffectFeatureType>(_ type: T.Type) {
    imageEffectDecoders[T.featureTypeKey] = { decoder, version in
      try T.decodeParameters(from: decoder, version: version)
    }
  }

  /// Registers a domain-feature params type for persistence.
  public mutating func register<T: PersistableFeature & DomainFeatureType>(_ type: T.Type) {
    domainDecoders[T.featureTypeKey] = { decoder, version in
      try T.decodeParameters(from: decoder, version: version)
    }
  }

  func containsImageEffect(_ key: FeatureTypeKey) -> Bool {
    imageEffectDecoders[key] != nil
  }

  func containsDomainFeature(_ key: FeatureTypeKey) -> Bool {
    domainDecoders[key] != nil
  }

  func decodeImageEffect(
    key: FeatureTypeKey,
    version: Int,
    from decoder: Decoder
  ) throws -> any ImageEffectFeatureType {
    guard let decode = imageEffectDecoders[key] else {
      throw ParametricDocumentCodecError.unregisteredFeatureType(key)
    }
    return try decode(decoder, version)
  }

  func decodeDomainFeature(
    key: FeatureTypeKey,
    version: Int,
    from decoder: Decoder
  ) throws -> any DomainFeatureType {
    guard let decode = domainDecoders[key] else {
      throw ParametricDocumentCodecError.unregisteredFeatureType(key)
    }
    return try decode(decoder, version)
  }

  /// The registry containing every Brightroom built-in feature.
  public static var brightroomDefault: ParametricFeatureTypeRegistry {
    var registry = ParametricFeatureTypeRegistry()
    registry.register(CropFeature.self)
    registry.register(PresetFeature.self)
    registry.register(EffectPipelineFeature.self)
    registry.register(ColorCubeFeature.self)
    registry.register(BrightnessFeature.self)
    registry.register(ContrastFeature.self)
    registry.register(SaturationFeature.self)
    registry.register(ExposureFeature.self)
    registry.register(HighlightsFeature.self)
    registry.register(ShadowsFeature.self)
    registry.register(HighlightShadowTintFeature.self)
    registry.register(TemperatureFeature.self)
    registry.register(SharpenFeature.self)
    registry.register(GaussianBlurFeature.self)
    registry.register(UnsharpMaskFeature.self)
    registry.register(VignetteFeature.self)
    registry.register(FadeFeature.self)
    return registry
  }
}

/// Encodes and decodes parametric documents.
public struct ParametricDocumentCodec: Sendable {

  /// The registered persistable feature types.
  public var types: ParametricFeatureTypeRegistry

  /// Creates a codec, starting from the Brightroom built-in registrations.
  public init(types: ParametricFeatureTypeRegistry = .brightroomDefault) {
    self.types = types
  }

  /// Registers an image-effect params type, UICollectionView style.
  public mutating func register<T: PersistableFeature & ImageEffectFeatureType>(_ type: T.Type) {
    types.register(type)
  }

  /// Registers a domain-feature params type, UICollectionView style.
  public mutating func register<T: PersistableFeature & DomainFeatureType>(_ type: T.Type) {
    types.register(type)
  }

  /// Encodes a document.
  public func encode(_ document: EditingDocument) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.userInfo[.parametricFeatureTypes] = types
    return try encoder.encode(document)
  }

  /// Decodes a document, resolving every feature to its registered type.
  public func decode(_ data: Data) throws -> EditingDocument {
    let decoder = JSONDecoder()
    decoder.userInfo[.parametricFeatureTypes] = types
    return try decoder.decode(EditingDocument.self, from: data)
  }
}

extension CodingUserInfoKey {

  /// Carries the codec's type registry through Codable coding.
  public static let parametricFeatureTypes = CodingUserInfoKey(
    rawValue: "BrightroomParametric.featureTypes"
  )!
}

// MARK: - Envelope coding

private enum EnvelopeKeys: String, CodingKey {
  case type
  case v
  case params
}

private func registry(from decoder: Decoder) throws -> ParametricFeatureTypeRegistry {
  guard
    let registry = decoder.userInfo[.parametricFeatureTypes] as? ParametricFeatureTypeRegistry
  else {
    throw ParametricDocumentCodecError.missingRegistry
  }
  return registry
}

private func registry(from encoder: Encoder) throws -> ParametricFeatureTypeRegistry {
  guard
    let registry = encoder.userInfo[.parametricFeatureTypes] as? ParametricFeatureTypeRegistry
  else {
    throw ParametricDocumentCodecError.missingRegistry
  }
  return registry
}

private func encodeEnvelope(
  _ feature: any Feature,
  into container: inout KeyedEncodingContainer<EnvelopeKeys>,
  isRegistered: (FeatureTypeKey) -> Bool
) throws {
  guard let persistable = feature as? any PersistableFeature else {
    throw ParametricDocumentCodecError.notPersistable(
      typeName: String(describing: type(of: feature))
    )
  }

  func write<T: PersistableFeature>(_ value: T) throws {
    // Fail at save time, not load time: a document the codec writes must be
    // decodable by the same codec.
    guard isRegistered(T.featureTypeKey) else {
      throw ParametricDocumentCodecError.unregisteredFeatureType(T.featureTypeKey)
    }
    try container.encode(T.featureTypeKey, forKey: .type)
    try container.encode(T.schemaVersion, forKey: .v)
    try value.encode(to: container.superEncoder(forKey: .params))
  }
  try write(persistable)
}

/// Codable box carrying an image effect through an envelope.
struct ParametricEffectBox: Codable {

  var value: any ImageEffectFeatureType

  init(_ value: any ImageEffectFeatureType) {
    self.value = value
  }

  init(from decoder: Decoder) throws {
    let types = try registry(from: decoder)
    let container = try decoder.container(keyedBy: EnvelopeKeys.self)
    let key = try container.decode(FeatureTypeKey.self, forKey: .type)
    let version = try container.decode(Int.self, forKey: .v)
    self.value = try types.decodeImageEffect(
      key: key,
      version: version,
      from: try container.superDecoder(forKey: .params)
    )
  }

  func encode(to encoder: Encoder) throws {
    let types = try registry(from: encoder)
    var container = encoder.container(keyedBy: EnvelopeKeys.self)
    try encodeEnvelope(value, into: &container, isRegistered: types.containsImageEffect)
  }
}

/// Codable box carrying a domain feature through an envelope.
struct ParametricDomainBox: Codable {

  var value: any DomainFeatureType

  init(_ value: any DomainFeatureType) {
    self.value = value
  }

  init(from decoder: Decoder) throws {
    let types = try registry(from: decoder)
    let container = try decoder.container(keyedBy: EnvelopeKeys.self)
    let key = try container.decode(FeatureTypeKey.self, forKey: .type)
    let version = try container.decode(Int.self, forKey: .v)
    self.value = try types.decodeDomainFeature(
      key: key,
      version: version,
      from: try container.superDecoder(forKey: .params)
    )
  }

  func encode(to encoder: Encoder) throws {
    let types = try registry(from: encoder)
    var container = encoder.container(keyedBy: EnvelopeKeys.self)
    try encodeEnvelope(value, into: &container, isRegistered: types.containsDomainFeature)
  }
}

// MARK: - Document Codable (boundary-only)

extension EditingDocument: Codable {

  /// The serialized format version of the structural spine (document, tree,
  /// local adjustments, mask vocabulary). Feature parameters carry their own
  /// per-type versions in their envelopes; this version is the migration hook
  /// for everything between them.
  public static let formatVersion = 1

  private enum Keys: String, CodingKey {
    case formatVersion
    case mainTree
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: Keys.self)
    let version = try container.decode(Int.self, forKey: .formatVersion)
    guard version == Self.formatVersion else {
      throw ParametricDocumentCodecError.unsupportedDocumentFormatVersion(version)
    }
    self.init(mainTree: try container.decode(MainTree.self, forKey: .mainTree))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Keys.self)
    try container.encode(Self.formatVersion, forKey: .formatVersion)
    try container.encode(mainTree, forKey: .mainTree)
  }
}

extension MainTree: Codable {

  private enum Keys: String, CodingKey {
    case features
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: Keys.self)
    self.init(features: try container.decode([MainFeature].self, forKey: .features))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Keys.self)
    try container.encode(features, forKey: .features)
  }
}

extension MainFeature: Codable {

  private enum Keys: String, CodingKey {
    case kind
    case feature
  }

  private enum Kind: String, Codable {
    case domain
    case effect
    case localAdjustment
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: Keys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .domain:
      self = .domain(try container.decode(ParametricDomainBox.self, forKey: .feature).value)
    case .effect:
      self = .effect(try container.decode(ParametricEffectBox.self, forKey: .feature).value)
    case .localAdjustment:
      self = .localAdjustment(
        try container.decode(LocalAdjustmentFeature.self, forKey: .feature)
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Keys.self)
    switch self {
    case let .domain(feature):
      try container.encode(Kind.domain, forKey: .kind)
      try container.encode(ParametricDomainBox(feature), forKey: .feature)
    case let .effect(feature):
      try container.encode(Kind.effect, forKey: .kind)
      try container.encode(ParametricEffectBox(feature), forKey: .feature)
    case let .localAdjustment(feature):
      try container.encode(Kind.localAdjustment, forKey: .kind)
      try container.encode(feature, forKey: .feature)
    }
  }
}

extension EffectPipeline: Codable {

  private enum Keys: String, CodingKey {
    case effects
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: Keys.self)
    self.init(
      effects: try container.decode([ParametricEffectBox].self, forKey: .effects).map(\.value)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Keys.self)
    try container.encode(effects.map(ParametricEffectBox.init), forKey: .effects)
  }
}

extension LocalAdjustmentFeature: Codable {

  private enum Keys: String, CodingKey {
    case id
    case isEnabled
    case maskTree
    case effectPipeline
    case blendMode
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: Keys.self)
    self.init(
      id: try container.decode(FeatureID.self, forKey: .id),
      isEnabled: try container.decode(Bool.self, forKey: .isEnabled),
      maskTree: try container.decode(MaskTree.self, forKey: .maskTree),
      effectPipeline: try container.decode(EffectPipeline.self, forKey: .effectPipeline),
      blendMode: try container.decode(LocalAdjustmentBlendMode.self, forKey: .blendMode)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Keys.self)
    try container.encode(id, forKey: .id)
    try container.encode(isEnabled, forKey: .isEnabled)
    try container.encode(maskTree, forKey: .maskTree)
    try container.encode(effectPipeline, forKey: .effectPipeline)
    try container.encode(blendMode, forKey: .blendMode)
  }
}

extension PresetFeature {

  private enum Keys: String, CodingKey {
    case id
    case isEnabled
    case name
    case identifier
    case effects
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: Keys.self)
    self.init(
      id: try container.decode(FeatureID.self, forKey: .id),
      isEnabled: try container.decode(Bool.self, forKey: .isEnabled),
      name: try container.decode(String.self, forKey: .name),
      identifier: try container.decode(String.self, forKey: .identifier),
      effects: try container.decode([ParametricEffectBox].self, forKey: .effects).map(\.value)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Keys.self)
    try container.encode(id, forKey: .id)
    try container.encode(isEnabled, forKey: .isEnabled)
    try container.encode(name, forKey: .name)
    try container.encode(identifier, forKey: .identifier)
    try container.encode(effects.map(ParametricEffectBox.init), forKey: .effects)
  }
}

// MARK: - Built-in registrations

extension CropFeature: PersistableFeature {
  public static let featureTypeKey: FeatureTypeKey = "brightroom.domain.crop"

  /// v2 added `rotation` + `straightenRadians`. v1 documents stored only the
  /// crop rect and decode with no rotation and zero straighten.
  public static var schemaVersion: Int { 2 }

  private struct V1Parameters: Decodable {
    var id: FeatureID
    var isEnabled: Bool
    var cropRect: CGRect
  }

  public static func decodeParameters(from decoder: Decoder, version: Int) throws -> CropFeature {
    switch version {
    case 2:
      return try CropFeature(from: decoder)
    case 1:
      let v1 = try V1Parameters(from: decoder)
      return CropFeature(
        id: v1.id,
        isEnabled: v1.isEnabled,
        cropRect: v1.cropRect
      )
    default:
      throw ParametricDocumentCodecError.unsupportedSchemaVersion(
        featureTypeKey,
        version: version
      )
    }
  }
}

extension PresetFeature: PersistableFeature, Codable {
  public static let featureTypeKey: FeatureTypeKey = "brightroom.effect.preset"
}

extension EffectPipelineFeature: PersistableFeature {
  public static let featureTypeKey: FeatureTypeKey = "brightroom.effect.pipeline"
}

extension ColorCubeFeature: PersistableFeature {
  public static let featureTypeKey: FeatureTypeKey = "brightroom.effect.color-cube"
}

extension BrightnessFeature: PersistableFeature {
  public static let featureTypeKey: FeatureTypeKey = "brightroom.effect.brightness"
}

extension ContrastFeature: PersistableFeature {
  public static let featureTypeKey: FeatureTypeKey = "brightroom.effect.contrast"
}

extension SaturationFeature: PersistableFeature {
  public static let featureTypeKey: FeatureTypeKey = "brightroom.effect.saturation"
}

extension ExposureFeature: PersistableFeature {
  public static let featureTypeKey: FeatureTypeKey = "brightroom.effect.exposure"
}

extension HighlightsFeature: PersistableFeature {
  public static let featureTypeKey: FeatureTypeKey = "brightroom.effect.highlights"
}

extension ShadowsFeature: PersistableFeature {
  public static let featureTypeKey: FeatureTypeKey = "brightroom.effect.shadows"
}

extension HighlightShadowTintFeature: PersistableFeature {
  public static let featureTypeKey: FeatureTypeKey = "brightroom.effect.highlight-shadow-tint"
}

extension TemperatureFeature: PersistableFeature {
  public static let featureTypeKey: FeatureTypeKey = "brightroom.effect.temperature"
}

extension SharpenFeature: PersistableFeature {
  public static let featureTypeKey: FeatureTypeKey = "brightroom.effect.sharpen"
}

extension GaussianBlurFeature: PersistableFeature {
  public static let featureTypeKey: FeatureTypeKey = "brightroom.effect.gaussian-blur"
}

extension UnsharpMaskFeature: PersistableFeature {
  public static let featureTypeKey: FeatureTypeKey = "brightroom.effect.unsharp-mask"
}

extension VignetteFeature: PersistableFeature {
  public static let featureTypeKey: FeatureTypeKey = "brightroom.effect.vignette"
}

extension FadeFeature: PersistableFeature {
  public static let featureTypeKey: FeatureTypeKey = "brightroom.effect.fade"
}
