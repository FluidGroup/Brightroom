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

import CoreGraphics
import CoreImage
import Foundation

/// A stable identifier for a feature definition.
///
/// Brightroom-provided features and app-provided features share the same type ID
/// namespace. The document model therefore does not need a built-in/custom
/// distinction; it only stores the ID needed to resolve behavior at render time.
public struct FeatureTypeID: RawRepresentable, Codable, Equatable, Hashable, Sendable, ExpressibleByStringLiteral {

  /// The serialized feature type identifier.
  public var rawValue: String

  /// Creates a feature type identifier.
  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  /// Creates a feature type identifier from a string literal.
  public init(stringLiteral value: String) {
    self.rawValue = value
  }
}

/// The placement and output contract of a feature definition.
public enum FeatureCapability: String, Codable, Equatable, Sendable {

  /// A main-tree operation that may change image extent or coordinate domain.
  case domain

  /// An extent-preserving image operation.
  case imageEffect

  /// A mask-tree operation that produces alpha.
  case mask
}

/// A serializable feature invocation.
///
/// `FeatureNode` is the common document shape for all operations. The payload is
/// kept as JSON so unknown feature types can round-trip through a document even
/// when the current registry cannot render them.
public struct FeatureNode: Codable, Equatable, Sendable {

  /// The registered feature definition to use when evaluating this node.
  public var typeID: FeatureTypeID

  /// The schema version used by `payload`.
  public var schemaVersion: Int

  /// The stable identity of this feature invocation.
  public var id: FeatureID

  /// A Boolean value indicating whether this feature participates in rendering.
  public var isEnabled: Bool

  /// The feature-specific serialized parameters.
  public var payload: JSONValue

  /// Creates a feature node from already-erased payload data.
  public init(
    typeID: FeatureTypeID,
    schemaVersion: Int,
    id: FeatureID = .init(),
    isEnabled: Bool = true,
    payload: JSONValue
  ) {
    self.typeID = typeID
    self.schemaVersion = schemaVersion
    self.id = id
    self.isEnabled = isEnabled
    self.payload = payload
  }

  /// Creates a feature node for a typed feature definition.
  public init<Definition: ParametricFeatureDefinition>(
    _ definition: Definition.Type,
    id: FeatureID = .init(),
    isEnabled: Bool = true,
    payload: Definition.Payload
  ) throws {
    self.init(
      typeID: Definition.typeID,
      schemaVersion: Definition.currentSchemaVersion,
      id: id,
      isEnabled: isEnabled,
      payload: try JSONValue(payload)
    )
  }

  /// Decodes this node's payload as the supplied feature definition's payload.
  public func decodePayload<Definition: ParametricFeatureDefinition>(
    as definition: Definition.Type
  ) throws -> Definition.Payload {
    try payload.decode(Definition.Payload.self)
  }
}

/// A JSON value used for type-erased feature payload storage.
public enum JSONValue: Codable, Equatable, Sendable {

  /// A JSON null value.
  case null

  /// A JSON Boolean value.
  case bool(Bool)

  /// A JSON number value.
  case number(Double)

  /// A JSON string value.
  case string(String)

  /// A JSON array value.
  case array([JSONValue])

  /// A JSON object value.
  case object([String: JSONValue])

  /// Encodes a typed value into a JSON payload.
  public init<Value: Encodable>(_ value: Value) throws {
    let data = try JSONEncoder().encode(value)
    let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    self = try JSONValue(object)
  }

  /// Decodes this JSON payload into a typed value.
  public func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
    let object = jsonObject
    let data = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
    return try JSONDecoder().decode(Value.self, from: data)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()

    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()

    switch self {
    case .null:
      try container.encodeNil()
    case let .bool(value):
      try container.encode(value)
    case let .number(value):
      try container.encode(value)
    case let .string(value):
      try container.encode(value)
    case let .array(value):
      try container.encode(value)
    case let .object(value):
      try container.encode(value)
    }
  }
}

/// Errors thrown while erasing or restoring feature payloads.
public enum FeaturePayloadCodingError: Error, Equatable, Sendable {

  /// The supplied object cannot be represented by `JSONValue`.
  case unsupportedJSONObject(String)
}

/// Common metadata for a feature definition.
public protocol ParametricFeatureDefinition: Sendable {

  /// The typed payload stored in a `FeatureNode`.
  associatedtype Payload: Codable & Equatable & Sendable

  /// The stable type identifier used by serialized documents.
  static var typeID: FeatureTypeID { get }

  /// The current payload schema version emitted by new nodes.
  static var currentSchemaVersion: Int { get }

  /// Validates a decoded payload before it is rendered.
  static func validate(payload: Payload, node: FeatureNode) throws
}

public extension ParametricFeatureDefinition {

  static func validate(payload: Payload, node: FeatureNode) throws {}
}

/// A feature definition that may change image domain.
public protocol DomainFeatureDefinition: ParametricFeatureDefinition {

  /// Applies the domain operation to the current image.
  static func apply(
    payload: Payload,
    node: FeatureNode,
    to image: CIImage,
    context: FeatureEvaluationContext
  ) throws -> CIImage
}

/// A feature definition that preserves image extent.
public protocol ImageEffectFeatureDefinition: ParametricFeatureDefinition {

  /// Applies the image effect to the current image.
  static func apply(
    payload: Payload,
    node: FeatureNode,
    to image: CIImage,
    context: FeatureEvaluationContext
  ) throws -> CIImage

  /// Returns nested effect nodes owned by this feature.
  static func childImageEffects(payload: Payload) -> [FeatureNode]
}

public extension ImageEffectFeatureDefinition {

  static func childImageEffects(payload: Payload) -> [FeatureNode] { [] }
}

/// A feature definition that renders an alpha mask.
public protocol MaskFeatureDefinition: ParametricFeatureDefinition {

  /// Renders this mask in the current image domain.
  static func renderMask(
    payload: Payload,
    node: FeatureNode,
    extent: CGRect,
    context: FeatureEvaluationContext
  ) throws -> CIImage

  /// Returns nested mask nodes owned by this feature.
  static func childMasks(payload: Payload) -> [FeatureNode]
}

public extension MaskFeatureDefinition {

  static func childMasks(payload: Payload) -> [FeatureNode] { [] }
}

/// Runtime dependencies used while evaluating feature definitions.
public struct FeatureEvaluationContext: Sendable {

  /// The registry that resolves feature type IDs.
  public var featureRegistry: FeatureRegistry

  /// The registry that provides Metal-backed Core Image kernels.
  public var kernelRegistry: ParametricKernelRegistry

  /// Creates an evaluation context.
  public init(
    featureRegistry: FeatureRegistry,
    kernelRegistry: ParametricKernelRegistry
  ) {
    self.featureRegistry = featureRegistry
    self.kernelRegistry = kernelRegistry
  }
}

/// A registry that resolves feature nodes into renderable behavior.
public struct FeatureRegistry: Sendable {

  private var domainDefinitions: [FeatureTypeID: AnyDomainFeatureDefinition] = [:]
  private var imageEffectDefinitions: [FeatureTypeID: AnyImageEffectFeatureDefinition] = [:]
  private var maskDefinitions: [FeatureTypeID: AnyMaskFeatureDefinition] = [:]

  /// Creates an empty feature registry.
  public init() {}

  /// Registers a domain feature definition.
  public mutating func registerDomainFeature<Definition: DomainFeatureDefinition>(
    _ definition: Definition.Type
  ) {
    domainDefinitions[Definition.typeID] = AnyDomainFeatureDefinition(definition)
  }

  /// Registers an image effect feature definition.
  public mutating func registerImageEffect<Definition: ImageEffectFeatureDefinition>(
    _ definition: Definition.Type
  ) {
    imageEffectDefinitions[Definition.typeID] = AnyImageEffectFeatureDefinition(definition)
  }

  /// Registers a mask feature definition.
  public mutating func registerMask<Definition: MaskFeatureDefinition>(
    _ definition: Definition.Type
  ) {
    maskDefinitions[Definition.typeID] = AnyMaskFeatureDefinition(definition)
  }

  /// Applies a registered domain feature.
  public func applyDomainFeature(
    _ node: FeatureNode,
    to image: CIImage,
    context: FeatureEvaluationContext
  ) throws -> CIImage {
    guard node.isEnabled else {
      return image
    }
    return try domainDefinition(for: node).apply(node, to: image, context: context)
  }

  /// Applies a registered image effect.
  public func applyImageEffect(
    _ node: FeatureNode,
    to image: CIImage,
    context: FeatureEvaluationContext
  ) throws -> CIImage {
    guard node.isEnabled else {
      return image
    }
    return try imageEffectDefinition(for: node).apply(node, to: image, context: context)
  }

  /// Renders a registered mask feature.
  public func renderMask(
    _ node: FeatureNode,
    extent: CGRect,
    context: FeatureEvaluationContext
  ) throws -> CIImage {
    try maskDefinition(for: node).renderMask(node, extent: extent, context: context)
  }

  /// Resolves a domain definition.
  public func domainDefinition(for node: FeatureNode) throws -> AnyDomainFeatureDefinition {
    guard let definition = domainDefinitions[node.typeID] else {
      throw FeatureRegistryError.unregisteredFeature(node.typeID, .domain)
    }
    return definition
  }

  /// Resolves an image-effect definition.
  public func imageEffectDefinition(for node: FeatureNode) throws -> AnyImageEffectFeatureDefinition {
    guard let definition = imageEffectDefinitions[node.typeID] else {
      throw FeatureRegistryError.unregisteredFeature(node.typeID, .imageEffect)
    }
    return definition
  }

  /// Resolves a mask definition.
  public func maskDefinition(for node: FeatureNode) throws -> AnyMaskFeatureDefinition {
    guard let definition = maskDefinitions[node.typeID] else {
      throw FeatureRegistryError.unregisteredFeature(node.typeID, .mask)
    }
    return definition
  }
}

/// Errors thrown by feature registry resolution.
public enum FeatureRegistryError: Error, Equatable, Sendable {

  /// No definition for the type ID has been registered for the requested capability.
  case unregisteredFeature(FeatureTypeID, FeatureCapability)
}

/// Type-erased domain feature definition.
public struct AnyDomainFeatureDefinition: Sendable {

  /// The registered feature type ID.
  public let typeID: FeatureTypeID

  /// The current payload schema version.
  public let currentSchemaVersion: Int

  private let _validate: @Sendable (FeatureNode) throws -> Void
  private let _apply: @Sendable (FeatureNode, CIImage, FeatureEvaluationContext) throws -> CIImage

  init<Definition: DomainFeatureDefinition>(_ definition: Definition.Type) {
    self.typeID = Definition.typeID
    self.currentSchemaVersion = Definition.currentSchemaVersion
    self._validate = { node in
      let payload = try node.decodePayload(as: Definition.self)
      try Definition.validate(payload: payload, node: node)
    }
    self._apply = { node, image, context in
      let payload = try node.decodePayload(as: Definition.self)
      try Definition.validate(payload: payload, node: node)
      return try Definition.apply(payload: payload, node: node, to: image, context: context)
    }
  }

  /// Validates a node payload for this definition.
  public func validate(_ node: FeatureNode) throws {
    try _validate(node)
  }

  /// Applies the feature to the current image.
  public func apply(
    _ node: FeatureNode,
    to image: CIImage,
    context: FeatureEvaluationContext
  ) throws -> CIImage {
    try _apply(node, image, context)
  }
}

/// Type-erased image effect feature definition.
public struct AnyImageEffectFeatureDefinition: Sendable {

  /// The registered feature type ID.
  public let typeID: FeatureTypeID

  /// The current payload schema version.
  public let currentSchemaVersion: Int

  private let _validate: @Sendable (FeatureNode) throws -> Void
  private let _apply: @Sendable (FeatureNode, CIImage, FeatureEvaluationContext) throws -> CIImage
  private let _childImageEffects: @Sendable (FeatureNode) throws -> [FeatureNode]

  init<Definition: ImageEffectFeatureDefinition>(_ definition: Definition.Type) {
    self.typeID = Definition.typeID
    self.currentSchemaVersion = Definition.currentSchemaVersion
    self._validate = { node in
      let payload = try node.decodePayload(as: Definition.self)
      try Definition.validate(payload: payload, node: node)
    }
    self._apply = { node, image, context in
      let payload = try node.decodePayload(as: Definition.self)
      try Definition.validate(payload: payload, node: node)
      return try Definition.apply(payload: payload, node: node, to: image, context: context)
    }
    self._childImageEffects = { node in
      let payload = try node.decodePayload(as: Definition.self)
      return Definition.childImageEffects(payload: payload)
    }
  }

  /// Validates a node payload for this definition.
  public func validate(_ node: FeatureNode) throws {
    try _validate(node)
  }

  /// Applies the feature to the current image.
  public func apply(
    _ node: FeatureNode,
    to image: CIImage,
    context: FeatureEvaluationContext
  ) throws -> CIImage {
    try _apply(node, image, context)
  }

  /// Returns nested image-effect nodes owned by this definition.
  public func childImageEffects(in node: FeatureNode) throws -> [FeatureNode] {
    try _childImageEffects(node)
  }
}

/// Type-erased mask feature definition.
public struct AnyMaskFeatureDefinition: Sendable {

  /// The registered feature type ID.
  public let typeID: FeatureTypeID

  /// The current payload schema version.
  public let currentSchemaVersion: Int

  private let _validate: @Sendable (FeatureNode) throws -> Void
  private let _renderMask: @Sendable (FeatureNode, CGRect, FeatureEvaluationContext) throws -> CIImage
  private let _childMasks: @Sendable (FeatureNode) throws -> [FeatureNode]

  init<Definition: MaskFeatureDefinition>(_ definition: Definition.Type) {
    self.typeID = Definition.typeID
    self.currentSchemaVersion = Definition.currentSchemaVersion
    self._validate = { node in
      let payload = try node.decodePayload(as: Definition.self)
      try Definition.validate(payload: payload, node: node)
    }
    self._renderMask = { node, extent, context in
      let payload = try node.decodePayload(as: Definition.self)
      try Definition.validate(payload: payload, node: node)
      return try Definition.renderMask(payload: payload, node: node, extent: extent, context: context)
    }
    self._childMasks = { node in
      let payload = try node.decodePayload(as: Definition.self)
      return Definition.childMasks(payload: payload)
    }
  }

  /// Validates a node payload for this definition.
  public func validate(_ node: FeatureNode) throws {
    try _validate(node)
  }

  /// Renders the feature mask.
  public func renderMask(
    _ node: FeatureNode,
    extent: CGRect,
    context: FeatureEvaluationContext
  ) throws -> CIImage {
    try _renderMask(node, extent, context)
  }

  /// Returns nested mask nodes owned by this definition.
  public func childMasks(in node: FeatureNode) throws -> [FeatureNode] {
    try _childMasks(node)
  }
}

private extension JSONValue {

  init(_ object: Any) throws {
    switch object {
    case _ as NSNull:
      self = .null
    case let value as NSNumber:
      if CFGetTypeID(value) == CFBooleanGetTypeID() {
        self = .bool(value.boolValue)
      } else {
        self = .number(value.doubleValue)
      }
    case let value as Bool:
      self = .bool(value)
    case let value as String:
      self = .string(value)
    case let value as [Any]:
      self = .array(try value.map(JSONValue.init))
    case let value as [String: Any]:
      self = .object(try value.mapValues(JSONValue.init))
    default:
      throw FeaturePayloadCodingError.unsupportedJSONObject(String(describing: type(of: object)))
    }
  }

  var jsonObject: Any {
    switch self {
    case .null:
      NSNull()
    case let .bool(value):
      value
    case let .number(value):
      value
    case let .string(value):
      value
    case let .array(value):
      value.map(\.jsonObject)
    case let .object(value):
      value.mapValues(\.jsonObject)
    }
  }
}
