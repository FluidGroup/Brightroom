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
  /// that adds the oriented source pixel size (`CropFeature` carries none) and
  /// the engine's editing projections.
  ///
  /// The named accessors (`crop`, `effects`, `localAdjustments`) are projections
  /// over the main tree, kept so callers that only care about the canonical
  /// arrangement do not need to walk features themselves. Their setters rewrite
  /// the corresponding feature in place.
  ///
  /// Pixel parameters use the BrightroomParametric vocabulary directly
  /// (`CropFeature`, `EffectPipelineFeature`/`EffectPipeline`,
  /// `LocalAdjustmentFeature`).
  public struct Edit: Equatable {

    /// The parametric editing document — the source of truth. Assembly (which
    /// features exist and in what order) is the host UI's responsibility; the
    /// engine evaluates the main tree as-is. The document always contains at
    /// least one crop domain feature; the last one acts as the final crop.
    public private(set) var document: EditingDocument

    /// The oriented source pixel size. `CropFeature` is expressed relative to
    /// this size (its rect is snapped against it); storing it on `Edit` keeps a
    /// document snapshot self-describing for history and tests.
    public var orientedImageSize: CGSize

    // MARK: - Well-known identities

    /// The identity of the global effects node in the canonical document.
    public static let globalEffectsID = FeatureID(
      rawValue: "brightroom.editing-stack.global-effects"
    )

    /// The identity of the final crop node.
    public static let finalCropID = FeatureID(
      rawValue: "brightroom.editing-stack.final-crop"
    )

    /// Creates the canonical default document: a neutral effects pipeline
    /// followed by the final crop. The crop is re-stamped with `finalCropID`.
    init(crop: CropFeature, orientedImageSize: CGSize) {
      var finalCrop = crop
      finalCrop.id = Self.finalCropID
      self.document = EditingDocument(
        mainTree: MainTree(features: [
          .effect(EffectPipelineFeature(id: Self.globalEffectsID, pipeline: .init())),
          .domain(finalCrop),
        ])
      )
      self.orientedImageSize = orientedImageSize
    }

    /// Creates a document from an explicit parametric document.
    ///
    /// The main tree must contain at least one crop domain feature.
    public init(document: EditingDocument, orientedImageSize: CGSize) {
      precondition(
        document.mainTree.features.contains(where: Self.isCropFeature),
        "An editing document requires at least one crop feature."
      )
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

    /// The effects state in document order; the preview refresh key. With the
    /// canonical bundled pipeline this is a single combined pipeline.
    var effectsSequence: [EffectPipeline] {
      [effects]
    }

    // MARK: - Feature classification

    private static func isCropFeature(_ feature: MainFeature) -> Bool {
      if case let .domain(domain) = feature, domain is CropFeature {
        return true
      }
      return false
    }

    private static func caseTag(_ feature: MainFeature) -> Int {
      switch feature {
      case .domain: return 0
      case .effect: return 1
      case .localAdjustment: return 2
      }
    }

    // MARK: - Feature list mutations

    private var finalCropIndex: Int {
      guard let index = features.lastIndex(where: Self.isCropFeature) else {
        preconditionFailure("An editing document requires at least one crop feature.")
      }
      return index
    }

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

    /// Inserts a feature before the final crop — the position for everything
    /// authored in the pre-final-crop domain.
    public mutating func insertFeatureBeforeFinalCrop(_ feature: MainFeature) {
      document.mainTree.features.insert(feature, at: finalCropIndex)
    }

    /// Inserts a feature at an explicit position.
    public mutating func insertFeature(_ feature: MainFeature, at index: Int) {
      document.mainTree.features.insert(feature, at: index)
    }

    /// Removes the feature with `id`. Crop features are not removable; the
    /// document must keep its final crop. Returns false when nothing was
    /// removed.
    @discardableResult
    public mutating func removeFeature(id: FeatureID) -> Bool {
      guard
        let index = features.firstIndex(where: { $0.id == id }),
        Self.isCropFeature(features[index]) == false
      else {
        return false
      }

      document.mainTree.features.remove(at: index)
      return true
    }

    // MARK: - Canonical projections

    /// The final crop: the last crop domain feature in the document.
    /// In orientation.up, y-up (Core Image) coordinates.
    public var crop: CropFeature {
      get {
        guard
          case let .domain(domain) = features[finalCropIndex],
          let crop = domain as? CropFeature
        else {
          preconditionFailure()
        }
        return crop
      }
      set {
        document.mainTree.features[finalCropIndex] = .domain(newValue)
      }
    }

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
    /// `globalEffectsID`.
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
          insertFeatureBeforeFinalCrop(
            .effect(EffectPipelineFeature(id: Self.globalEffectsID, pipeline: newValue))
          )
        }
      }
    }

    /// All local adjustments in document order.
    ///
    /// The setter is position-preserving: adjustments matched by id update
    /// their feature in place, removed adjustments drop their feature, and
    /// new adjustments insert before the final crop. Reordering existing
    /// adjustments is not expressible through this projection — mutate the
    /// document directly.
    public var localAdjustments: [LocalAdjustmentFeature] {
      get {
        features.compactMap {
          if case let .localAdjustment(adjustment) = $0 {
            return adjustment
          }
          return nil
        }
      }
      set {
        var remaining = newValue
        var features = document.mainTree.features
        for index in features.indices.reversed() {
          guard case let .localAdjustment(existing) = features[index] else {
            continue
          }
          if let matched = remaining.firstIndex(where: { $0.id == existing.id }) {
            let adjustment = remaining.remove(at: matched)
            features[index] = .localAdjustment(adjustment)
          } else {
            features.remove(at: index)
          }
        }
        document.mainTree.features = features
        for adjustment in remaining {
          insertFeatureBeforeFinalCrop(.localAdjustment(adjustment))
        }
      }
    }

    func isRenderingEquivalent(to other: Self) -> Bool {
      guard orientedImageSize == other.orientedImageSize else {
        return false
      }
      let lhsFeatures = features
      let rhsFeatures = other.features
      guard lhsFeatures.count == rhsFeatures.count else {
        return false
      }

      return zip(lhsFeatures, rhsFeatures).allSatisfy { lhs, rhs in
        // Crops compare through the engine's integer pixel-snap (sub-pixel
        // differences that snap to the same render rect are equivalent); every
        // other feature uses exact value equality via `MainFeature ==`.
        if
          case let .domain(a) = lhs, let cropA = a as? CropFeature,
          case let .domain(b) = rhs, let cropB = b as? CropFeature
        {
          return cropsRenderingEquivalent(cropA, cropB)
        }
        return lhs == rhs
      }
    }

    private func cropsRenderingEquivalent(_ a: CropFeature, _ b: CropFeature) -> Bool {
      a.renderCrop(orientedImageSize: orientedImageSize)
        == b.renderCrop(orientedImageSize: orientedImageSize)
    }
  }
}
