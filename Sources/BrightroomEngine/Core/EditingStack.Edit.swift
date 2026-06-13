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
  /// All editing state is stored as an ordered `features` list — the list
  /// order is the evaluation order. The named accessors (`crop`, `effects`,
  /// `localAdjustments`) are projections over that list, kept so callers that
  /// only care about the canonical arrangement do not need to walk features
  /// themselves. Their setters rewrite the corresponding feature in place.
  ///
  /// Pixel parameters use the BrightroomParametric vocabulary
  /// (`EffectPipeline`, `LocalAdjustmentFeature`).
  public struct Edit: Equatable {

    /// The ordered editing document. Assembly — which features exist and in
    /// what order — is the host UI's responsibility; the engine evaluates the
    /// list as-is. The document always contains at least one `.crop` feature;
    /// the last one acts as the final crop.
    public private(set) var features: [EditingFeature]

    /// Creates the canonical default document: a neutral effects pipeline
    /// followed by the final crop.
    init(crop: EditingCrop) {
      self.features = [
        .init(id: EditingFeature.globalEffectsID, payload: .effects(.init())),
        .init(id: EditingFeature.finalCropID, payload: .crop(crop)),
      ]
    }

    /// Creates a document from an explicit feature arrangement.
    ///
    /// The list must contain at least one `.crop` feature.
    public init(features: [EditingFeature]) {
      precondition(
        features.contains(where: { $0.payload.kind == .crop }),
        "An editing document requires at least one crop feature."
      )
      self.features = features
    }

    public var imageSize: CGSize {
      crop.imageSize
    }

    /// Every effects pipeline in document order; the preview refresh key.
    var effectsSequence: [EffectPipeline] {
      features.compactMap {
        if case let .effects(pipeline) = $0.payload {
          return pipeline
        }
        return nil
      }
    }

    // MARK: - Feature list mutations

    private var finalCropIndex: Int {
      guard let index = features.lastIndex(where: { $0.payload.kind == .crop }) else {
        preconditionFailure("An editing document requires at least one crop feature.")
      }
      return index
    }

    /// Replaces the payload of the feature with `id`, keeping the payload
    /// kind stable. Returns false when the feature does not exist or the
    /// mutation changed the payload kind.
    @discardableResult
    public mutating func updateFeature(
      id: FeatureID,
      mutate: (inout EditingFeature.Payload) -> Void
    ) -> Bool {
      guard let index = features.firstIndex(where: { $0.id == id }) else {
        return false
      }

      var payload = features[index].payload
      let kind = payload.kind
      mutate(&payload)

      guard payload.kind == kind else {
        assertionFailure("Feature mutations must keep the payload kind stable.")
        return false
      }

      features[index].payload = payload
      return true
    }

    /// Inserts a feature before the final crop — the position for everything
    /// authored in the pre-final-crop domain.
    public mutating func insertFeatureBeforeFinalCrop(_ feature: EditingFeature) {
      features.insert(feature, at: finalCropIndex)
    }

    /// Inserts a feature at an explicit position.
    public mutating func insertFeature(_ feature: EditingFeature, at index: Int) {
      features.insert(feature, at: index)
    }

    /// Removes the feature with `id`. Crop features are not removable; the
    /// document must keep its final crop. Returns false when nothing was
    /// removed.
    @discardableResult
    public mutating func removeFeature(id: FeatureID) -> Bool {
      guard
        let index = features.firstIndex(where: { $0.id == id }),
        features[index].payload.kind != .crop
      else {
        return false
      }

      features.remove(at: index)
      return true
    }

    // MARK: - Canonical projections

    /// The final crop: the last crop feature in the document.
    /// In orientation.up.
    public var crop: EditingCrop {
      get {
        guard case let .crop(crop) = features[finalCropIndex].payload else {
          preconditionFailure()
        }
        return crop
      }
      set {
        features[finalCropIndex].payload = .crop(newValue)
      }
    }

    /// The first effects pipeline, or an empty pipeline when the document
    /// has none.
    public var effects: EffectPipeline {
      get {
        for feature in features {
          if case let .effects(pipeline) = feature.payload {
            return pipeline
          }
        }
        return .init()
      }
      set {
        if let index = features.firstIndex(where: { $0.payload.kind == .effects }) {
          features[index].payload = .effects(newValue)
        } else {
          // Canonical-arrangement convenience: hosts composing custom
          // documents insert the feature explicitly instead.
          insertFeatureBeforeFinalCrop(
            .init(id: EditingFeature.globalEffectsID, payload: .effects(newValue))
          )
        }
      }
    }

    /// All local adjustments in document order.
    ///
    /// The setter is position-preserving: adjustments matched by id update
    /// their feature in place, removed adjustments drop their feature, and
    /// new adjustments insert before the final crop. Reordering existing
    /// adjustments is not expressible through this projection — mutate
    /// `features` directly.
    public var localAdjustments: [LocalAdjustmentFeature] {
      get {
        features.compactMap {
          if case let .localAdjustment(adjustment) = $0.payload {
            return adjustment
          }
          return nil
        }
      }
      set {
        var remaining = newValue
        for index in features.indices.reversed() {
          guard case let .localAdjustment(existing) = features[index].payload else {
            continue
          }
          if let matched = remaining.firstIndex(where: { $0.id == existing.id }) {
            let adjustment = remaining.remove(at: matched)
            features[index].id = adjustment.id
            features[index].payload = .localAdjustment(adjustment)
          } else {
            features.remove(at: index)
          }
        }
        for adjustment in remaining {
          insertFeatureBeforeFinalCrop(.init(localAdjustment: adjustment))
        }
      }
    }

    func isRenderingEquivalent(to other: Self) -> Bool {
      guard features.count == other.features.count else {
        return false
      }

      return zip(features, other.features).allSatisfy { lhs, rhs in
        switch (lhs.payload, rhs.payload) {
        case let (.crop(a), .crop(b)):
          return a.isRenderingEquivalent(to: b)
        case let (.effects(a), .effects(b)):
          return a == b
        case let (.localAdjustment(a), .localAdjustment(b)):
          return a == b
        default:
          return false
        }
      }
    }
  }
}
