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
public nonisolated struct ToneCurveFeature: ImageEffectFeatureType {

  /// The interpretation of the stop shaper, YRGB composition, and sampled table.
  ///
  /// The version is part of the render identity. A host that stores authored
  /// curves can store it too, so a future interpretation cannot silently change
  /// the pixels of an existing edit.
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
