//
// Copyright (c) 2021 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
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

import CoreImage
import Foundation
import UIKit

import BrightroomParametric

extension EditingStack {

  /// The editing document.
  ///
  /// All editing state lives in a parametric `EditingDocument` — its
  /// `mainTree.features` order is the evaluation order. `Edit` is a thin wrapper
  /// that adds the oriented source pixel size and the engine's editing
  /// projections.
  ///
  /// The remaining named accessors are compatibility projections over the main
  /// tree. Crop is intentionally not projected here: crop nodes are addressed
  /// through `EditingFeatureTree` by feature identity so multiple crop Features
  /// can coexist without `Edit` choosing one as special.
  ///
  /// Pixel parameters use the BrightroomParametric vocabulary directly
  /// (`CropFeature`, `EffectPipelineFeature`/`EffectPipeline`,
  /// `LocalAdjustmentFeature`).
  public struct Edit: Equatable {

    /// The parametric editing document — the source of truth. Assembly (which
    /// features exist and in what order) is the host UI's responsibility; the
    /// engine evaluates the main tree as-is.
    public private(set) var document: EditingDocument

    /// The oriented source pixel size. Storing it on `Edit` keeps a document
    /// snapshot self-describing for history and tests.
    public var orientedImageSize: CGSize

    /// Creates a document from an explicit parametric document.
    public init(document: EditingDocument, orientedImageSize: CGSize) {
      self.document = document
      self.orientedImageSize = orientedImageSize
    }

    /// The oriented source pixel size.
    public var imageSize: CGSize {
      orientedImageSize
    }

    /// The ordered main features, in evaluation order.
    public var features: [MainFeature] {
      document.mainTree.features
    }

    /// The effect nodes in document order; the preview refresh key.
    var effectFeatures: [MainFeature] {
      features.filter {
        if case .effect = $0 {
          return true
        }
        return false
      }
    }

    // MARK: - Feature classification

    private static func caseTag(_ feature: MainFeature) -> Int {
      switch feature {
      case .domain: return 0
      case .effect: return 1
      case .localAdjustment: return 2
      }
    }

    // MARK: - Feature list mutations

    /// Replaces the feature with `id`, keeping its case stable. Returns false
    /// when the feature does not exist or the mutation changed the case
    /// (domain / effect / localAdjustment).
    @discardableResult
    public mutating func updateFeature(
      id: FeatureID,
      mutate: (inout MainFeature) -> Void
    ) -> Bool {
      guard let index = features.firstIndex(where: { $0.id == id }) else {
        return false
      }

      var feature = document.mainTree.features[index]
      let tag = Self.caseTag(feature)
      mutate(&feature)

      guard Self.caseTag(feature) == tag else {
        assertionFailure("Feature mutations must keep the feature case stable.")
        return false
      }

      document.mainTree.features[index] = feature
      return true
    }

    /// Inserts a feature at an explicit position.
    public mutating func insertFeature(_ feature: MainFeature, at index: Int) {
      document.mainTree.features.insert(feature, at: index)
    }

    /// Replaces the ordered feature list.
    ///
    /// Use this for FeatureTree-level operations that need to preserve positions
    /// while removing and inserting several nodes as one document edit.
    public mutating func replaceFeatures(_ features: [MainFeature]) {
      document.mainTree.features = features
    }

    /// Removes the feature with `id`. Returns false when nothing was removed.
    @discardableResult
    public mutating func removeFeature(id: FeatureID) -> Bool {
      guard let index = features.firstIndex(where: { $0.id == id }) else {
        return false
      }

      document.mainTree.features.remove(at: index)
      return true
    }

    // MARK: - Canonical projections

    /// The index of the bundled effect-pipeline node, if present.
    private var bundledEffectIndex: Int? {
      features.firstIndex { feature in
        if case let .effect(effect) = feature, effect is EffectPipelineFeature {
          return true
        }
        return false
      }
    }

    /// The global effects pipeline.
    ///
    /// The getter returns the bundled `EffectPipelineFeature`'s pipeline when
    /// present, and otherwise GATHERS any scattered raw effect features into one
    /// pipeline (back-compat for documents saved before the bundle existed). The
    /// setter always writes the canonical bundled node, anchored at
    /// `EditingFeatureTree.globalEffectsNodeID`.
    public var effects: EffectPipeline {
      get {
        if
          let index = bundledEffectIndex,
          case let .effect(effect) = features[index],
          let bundle = effect as? EffectPipelineFeature
        {
          return bundle.pipeline
        }
        let scattered = features.compactMap { feature -> (any ImageEffectFeatureType)? in
          if case let .effect(effect) = feature {
            return effect
          }
          return nil
        }
        return EffectPipeline(effects: scattered)
      }
      set {
        if let index = bundledEffectIndex {
          let id = features[index].id
          document.mainTree.features[index] = .effect(
            EffectPipelineFeature(id: id, pipeline: newValue)
          )
        } else {
          insertFeature(
            .effect(
              EffectPipelineFeature(
                id: EditingFeatureTree.globalEffectsNodeID,
                pipeline: newValue
              )
            ),
            at: 0
          )
        }
      }
    }

    /// All local adjustments in document order.
    ///
    /// Mutating the local-adjustment list is FeatureTree policy because new
    /// layers need an insertion point in the ordered feature stack.
    public var localAdjustments: [LocalAdjustmentFeature] {
      features.compactMap {
        if case let .localAdjustment(adjustment) = $0 {
          return adjustment
        }
        return nil
      }
    }

  }
}
