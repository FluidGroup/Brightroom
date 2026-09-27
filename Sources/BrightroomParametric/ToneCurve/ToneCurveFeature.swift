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
///
/// Equality compares the authored `value`, including interior points on the
/// diagonal that do not change pixels. The derived render plan does not take
/// part. To ask whether two curves render the same, compare their
/// `ToneCurveFeature.RenderKey(curves:)`.
public nonisolated struct ToneCurveFeature: ImageEffect, Equatable {

  /// The interpretation of the stop shaper, YRGB composition, and sampled table.
  ///
  /// The version is part of the render identity. A host that stores authored
  /// curves can store it too, so a future interpretation cannot silently change
  /// the pixels of an existing edit.
  public static let semanticVersion = 4

  /// The four normalized curves authored by the shared editor.
  public let curves: Curves

  private let renderPlan: ToneCurveRenderPlan?

  /// Creates a feature and resolves its sampled render plan exactly once.
  public init(curves: Curves) {
    self.curves = curves
    self.renderPlan = ToneCurveRenderPlanCache.shared.plan(for: curves)
  }

  /// Evaluates the precompiled plan while preserving a neutral exact bypass.
  ///
  /// A curve whose render identity is neutral
  /// (`ToneCurveFeature.RenderKey(activeCurves: value) == nil`) returns `image`
  /// itself.
  public func apply(
    to image: CIImage,
    context: FeatureEvaluationContext
  ) throws -> CIImage {
    guard let renderPlan else { return image }
    return try ToneCurveRecipe.apply(to: image, plan: renderPlan)
  }

  /// Compares the authored curves; the derived render plan does not take part.
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.curves == rhs.curves
  }
}

/// Shares the latest compiled curve between Preview, Export, and LUT stills.
///
/// Interactive editing normally advances one value at a time. A one-entry
/// cache prevents every visible LUT cell from rebuilding the same four 4,096
/// sample tables while keeping memory bounded as authored coordinates change.
private nonisolated final class ToneCurveRenderPlanCache: Sendable {

  struct Entry: Sendable {
    let identity: ToneCurveFeature.RenderKey
    let plan: ToneCurveRenderPlan
  }

  static let shared = ToneCurveRenderPlanCache()

  private let storage = OSAllocatedUnfairLock<Entry?>(initialState: nil)

  func plan(for curves: ToneCurveFeature.Curves) -> ToneCurveRenderPlan? {
    guard let identity = ToneCurveFeature.RenderKey(activeCurves: curves) else {
      return nil
    }

    return storage.withLock { entry in
      if let entry, entry.identity == identity {
        return entry.plan
      }
      guard let plan = ToneCurveRenderPlan(curves: curves) else { return nil }
      entry = Entry(identity: identity, plan: plan)
      return plan
    }
  }
}
