//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import CoreImage
import Foundation
import os

/// A scene-linear YRGB tone-curve effect in extended-linear Display-P3.
///
/// Constructing the feature resolves an immutable render plan once. Frame
/// evaluation then reuses that plan and its cached Core Image table.
/// RGB curves preserve the input luminance, then the Y curve sets the final
/// luminance. Callers must evaluate the recipe in an extended-linear Display-P3
/// working color space with floating-point precision.
public nonisolated struct ToneCurveFeature: ImageEffectFeatureType, PersistableFeature {

  /// The stable document type key for this effect.
  public static let featureTypeKey: FeatureTypeKey = "brightroom.effect.tone-curve"

  /// The parameter-envelope schema accepted by this implementation.
  public static let schemaVersion = 1

  /// The interpretation of the stop shaper, YRGB composition, and sampled table.
  ///
  /// Persisted values carry this version so a future interpretation cannot
  /// silently change the pixels of an existing document.
  public static let semanticVersion = 4

  /// Stable identity of the document feature node.
  public let id: FeatureID

  /// The four normalized curves authored by the shared editor.
  public let value: ToneCurveEditorValue

  /// Whether at least one channel changes the mathematical identity mapping.
  public let isEnabled: Bool

  private let renderPlan: ToneCurveRenderPlan?

  /// Creates a feature and resolves its sampled render plan exactly once.
  /// Supply a distinct identifier when a document contains multiple curves.
  public init(
    id: FeatureID = FeatureID(rawValue: "brightroom.tone-curve"),
    value: ToneCurveEditorValue
  ) {
    let renderPlan = ToneCurveRenderPlanCache.shared.plan(for: value)
    self.id = id
    self.value = value
    self.isEnabled = renderPlan != nil
    self.renderPlan = renderPlan
  }

  /// Evaluates the precompiled plan while preserving a neutral exact bypass.
  public func apply(
    to image: CIImage,
    context: FeatureEvaluationContext
  ) throws -> CIImage {
    guard let renderPlan else { return image }
    return try ToneCurveRenderer.apply(to: image, plan: renderPlan)
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id
      && lhs.isEnabled == rhs.isEnabled
      && lhs.renderPlan?.identity == rhs.renderPlan?.identity
  }

  /// Restores authored values and reconstructs the derived render plan.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let semanticVersion = try container.decode(Int.self, forKey: .semanticVersion)
    guard semanticVersion == Self.semanticVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .semanticVersion,
        in: container,
        debugDescription: "Unsupported tone curve rendering semantic version: \(semanticVersion)."
      )
    }
    self.init(
      id: try container.decode(FeatureID.self, forKey: .id),
      value: try container.decode(ValueParameters.self, forKey: .value).value
    )
  }

  /// Saves authored values without persisting sampled tables or cached images.
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(ValueParameters(value), forKey: .value)
    try container.encode(Self.semanticVersion, forKey: .semanticVersion)
  }

  /// The on-disk shape is private so serialization does not become a runtime
  /// requirement of the editor's value model.
  private struct ValueParameters: Codable {
    let y: CurveParameters
    let red: CurveParameters
    let green: CurveParameters
    let blue: CurveParameters

    var value: ToneCurveEditorValue {
      ToneCurveEditorValue(y: y.curve, red: red.curve, green: green.curve, blue: blue.curve)
    }

    init(_ value: ToneCurveEditorValue) {
      y = CurveParameters(value.y)
      red = CurveParameters(value.red)
      green = CurveParameters(value.green)
      blue = CurveParameters(value.blue)
    }
  }

  /// Validates external coordinates before creating the model used by spline evaluation.
  private struct CurveParameters: Codable {
    let curve: ToneCurve

    init(_ curve: ToneCurve) {
      self.curve = curve
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: Keys.self)
      let points = try container.decode([PointParameters].self, forKey: .points)
      guard let curve = ToneCurve(validating: points.map(\.point)) else {
        throw DecodingError.dataCorruptedError(
          forKey: .points,
          in: container,
          debugDescription: "Tone curve points violate the authored curve invariants."
        )
      }
      self.curve = curve
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: Keys.self)
      try container.encode(curve.points.map(PointParameters.init), forKey: .points)
    }

    private enum Keys: String, CodingKey {
      case points
    }
  }

  private struct PointParameters: Codable {
    /// Mirrors stable editor identity without coupling the runtime enum to Codable.
    enum Identity: Codable {
      case blackEndpoint
      case whiteEndpoint
      case interior(UUID)
    }

    let id: Identity
    let input: Double
    let output: Double

    var point: ToneCurve.Point {
      let pointID: ToneCurve.Point.ID
      switch id {
      case .blackEndpoint:
        pointID = .blackEndpoint
      case .whiteEndpoint:
        pointID = .whiteEndpoint
      case .interior(let uuid):
        pointID = .interior(uuid)
      }
      return ToneCurve.Point(id: pointID, input: input, output: output)
    }

    init(_ point: ToneCurve.Point) {
      switch point.id {
      case .blackEndpoint:
        id = .blackEndpoint
      case .whiteEndpoint:
        id = .whiteEndpoint
      case .interior(let uuid):
        id = .interior(uuid)
      }
      input = point.input
      output = point.output
    }
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case value
    case semanticVersion
  }
}

/// Shares the latest compiled curve between Preview, Export, and LUT stills.
///
/// Interactive editing normally advances one value at a time. A one-entry
/// cache prevents every visible LUT cell from rebuilding the same four 4,096
/// sample tables while keeping memory bounded as authored coordinates change.
private nonisolated final class ToneCurveRenderPlanCache: Sendable {

  struct Entry: Sendable {
    let identity: ToneCurveRenderIdentity
    let plan: ToneCurveRenderPlan
  }

  static let shared = ToneCurveRenderPlanCache()

  private let storage = OSAllocatedUnfairLock<Entry?>(initialState: nil)

  func plan(for value: ToneCurveEditorValue) -> ToneCurveRenderPlan? {
    guard let identity = ToneCurveRenderIdentity(activeValue: value) else {
      return nil
    }

    return storage.withLock { entry in
      if let entry, entry.identity == identity {
        return entry.plan
      }
      guard let plan = ToneCurveRenderPlan(value: value) else { return nil }
      entry = Entry(identity: identity, plan: plan)
      return plan
    }
  }
}
