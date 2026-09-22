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
import Foundation
import BrightroomParametric

/// A position between features in a feature tree where the evaluated image can
/// be observed.
///
/// `docs/vision-of-editing.md` separates the point being viewed from the point
/// being adjusted. UI components receive a `FeatureTreePoint` to decide which
/// evaluated result to display while a different feature is being edited.
public enum FeatureTreePoint: Equatable, Sendable {

  /// Before any feature; the source image domain.
  case source

  /// The result immediately after the feature with the given identity.
  case after(FeatureID)

  /// After the last feature; the document output domain.
  case output
}

/// A FeatureTree view of `EditingStack.Edit`.
///
/// The tree is the contract between `EditingStack` and feature-editing UI
/// components: the UI previews the evaluated result at a `FeatureTreePoint`
/// and edits a feature node that may live at a different point.
///
/// The document IS the feature list — `Edit.features` — so this view mirrors
/// it one-to-one. Node order is evaluation order. Mutations go through
/// `EditingStack.updateFeature(id:mutate:)` and friends, which rewrite
/// `Edit.features`; the tree itself never stores pixels or UI state.
public struct EditingFeatureTree: Equatable {

  /// A feature node with a stable identity.
  public typealias Node = MainFeature

  /// The features evaluated in source-to-output order.
  public private(set) var nodes: [Node]

  // MARK: - Well-known identities

  /// The identity of the global effects node.
  ///
  /// Present in every canonical document, so
  /// UI can anchor editing affordances to a stable identity.
  public static let globalEffectsNodeID = FeatureID(
    rawValue: "brightroom.editing-stack.global-effects"
  )

  /// The identity of the final crop node.
  public static let finalCropNodeID = FeatureID(
    rawValue: "brightroom.editing-stack.final-crop"
  )

  /// Creates the canonical default document used by Photos-style editors.
  ///
  /// This is FeatureTree policy rather than `EditingStack.Edit` storage policy:
  /// the stack stores whatever ordered features the document carries, while this
  /// factory chooses the built-in arrangement of global effects followed by the
  /// final crop.
  public static func canonicalDocument(finalCrop crop: CropFeature) -> EditingDocument {
    var finalCrop = crop
    finalCrop.id = finalCropNodeID
    return EditingDocument(
      mainTree: MainTree(features: [
        .effect(EffectPipelineFeature(id: globalEffectsNodeID, pipeline: .init())),
        .domain(finalCrop),
      ])
    )
  }

  /// Creates the canonical default edit used when an `EditingStack` first loads
  /// an image.
  public static func canonicalEdit(
    finalCrop crop: CropFeature,
    orientedImageSize: CGSize
  ) -> EditingStack.Edit {
    EditingStack.Edit(
      document: canonicalDocument(finalCrop: crop),
      orientedImageSize: orientedImageSize
    )
  }

  // MARK: - Projection

  /// Mirrors an `EditingStack.Edit`'s feature list one-to-one.
  public init(edit: EditingStack.Edit) {
    self.nodes = edit.features
  }

  // MARK: - Accessors

  /// The node with the given identity.
  public func node(id: FeatureID) -> Node? {
    nodes.first(where: { $0.id == id })
  }

  /// The index of the node with the given identity.
  public func index(of id: FeatureID) -> Int? {
    nodes.firstIndex(where: { $0.id == id })
  }

  /// The crop feature addressed by a tree identity.
  public func crop(id: FeatureID) -> CropFeature? {
    guard
      case let .domain(domain)? = node(id: id),
      let crop = domain as? CropFeature
    else {
      return nil
    }
    return crop
  }

  /// The final crop feature in the built-in Photos-style arrangement.
  public var finalCrop: CropFeature? {
    crop(id: Self.finalCropNodeID)
  }

  /// The global effects feature.
  public var globalEffects: EffectPipeline? {
    guard
      case let .effect(effect)? = node(id: Self.globalEffectsNodeID),
      let bundle = effect as? EffectPipelineFeature
    else {
      return nil
    }
    return bundle.pipeline
  }

  /// The local adjustment nodes in evaluation order.
  public var localAdjustmentNodes: [Node] {
    nodes.filter {
      if case .localAdjustment = $0 {
        return true
      }
      return false
    }
  }

  /// The local adjustments in evaluation order.
  public var localAdjustments: [LocalAdjustmentFeature] {
    localAdjustmentNodes.compactMap {
      guard case let .localAdjustment(adjustment) = $0 else {
        return nil
      }
      return adjustment
    }
  }

  /// The local adjustment addressed by a tree identity.
  public func localAdjustment(id: FeatureID) -> LocalAdjustmentFeature? {
    guard case let .localAdjustment(adjustment)? = node(id: id) else {
      return nil
    }
    return adjustment
  }

  // MARK: - Point resolution

  /// The number of leading features applied at the given point.
  ///
  /// Returns nil when the point references an unknown feature.
  public func appliedFeatureCount(at point: FeatureTreePoint) -> Int? {
    switch point {
    case .source:
      return 0
    case let .after(id):
      guard let index = index(of: id) else {
        return nil
      }
      return index + 1
    case .output:
      return nodes.count
    }
  }

  /// Whether the evaluated image at `point` includes the feature `id`.
  ///
  /// Returns nil when either the point or the feature is unknown.
  public func point(_ point: FeatureTreePoint, includes id: FeatureID) -> Bool? {
    guard
      let appliedCount = appliedFeatureCount(at: point),
      let featureIndex = index(of: id)
    else {
      return nil
    }

    return featureIndex < appliedCount
  }

  // MARK: - Mutation core

  /// Whether a main-tree node is a crop domain feature.
  public static func isCropFeature(_ feature: MainFeature) -> Bool {
    if case let .domain(domain) = feature, domain is CropFeature {
      return true
    }
    return false
  }

  /// Applies a payload mutation to the node with `id` inside `edit`.
  ///
  /// The mutation must keep the payload kind stable. Returns false when the
  /// node does not exist or the mutation changed the payload kind.
  @discardableResult
  static func updateFeature(
    id: FeatureID,
    in edit: inout EditingStack.Edit,
    mutate: (inout MainFeature) -> Void
  ) -> Bool {
    edit.updateFeature(id: id, mutate: mutate)
  }

  /// Replaces a crop node by identity, preserving the node identity even when
  /// the caller built the replacement from transient UI state.
  @discardableResult
  static func updateCropFeature(
    id: FeatureID,
    in edit: inout EditingStack.Edit,
    with crop: CropFeature
  ) -> Bool {
    updateFeature(id: id, in: &edit) { feature in
      guard case .domain = feature else {
        return
      }

      var crop = crop
      crop.id = id
      feature = .domain(crop)
    }
  }

  /// Removes the feature with `id` from `edit`.
  ///
  /// Returns false when nothing was removed.
  @discardableResult
  static func removeFeature(
    id: FeatureID,
    from edit: inout EditingStack.Edit
  ) -> Bool {
    guard
      let node = EditingFeatureTree(edit: edit).node(id: id),
      isCropFeature(node) == false
    else {
      return false
    }

    return edit.removeFeature(id: id)
  }

  /// Replaces all local-adjustment nodes while preserving existing node
  /// positions and inserting new nodes before `insertionTargetID`.
  ///
  /// The insertion target is host policy. PhotosCrop passes the final crop node
  /// so newly painted local adjustments stay in the pre-final-crop domain.
  public static func replaceLocalAdjustments(
    _ localAdjustments: [LocalAdjustmentFeature],
    in edit: inout EditingStack.Edit,
    insertingBefore insertionTargetID: FeatureID?
  ) {
    var remaining = localAdjustments
    var features = edit.features
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

    let insertionIndex = insertionTargetID
      .flatMap { id in features.firstIndex(where: { $0.id == id }) }
      ?? features.count
    features.insert(contentsOf: remaining.map(MainFeature.localAdjustment), at: insertionIndex)
    edit.replaceFeatures(features)
  }
}

// MARK: - EditingStack + FeatureTree

extension EditingStack {

  /// The FeatureTree projection of the current edit, once loading completed.
  public var featureTree: EditingFeatureTree? {
    loadedState.map { EditingFeatureTree(edit: $0.currentEdit) }
  }

  /// Applies a payload mutation to the feature node with `id`.
  ///
  /// Returns false when the stack has not loaded, the node does not exist, or
  /// the mutation changed the payload kind.
  @discardableResult
  public func updateFeature(
    id: FeatureID,
    mutate: (inout MainFeature) -> Void
  ) -> Bool {
    _pixelengine_ensureMainThread()

    guard var edit = loadedState?.currentEdit else {
      return false
    }

    guard EditingFeatureTree.updateFeature(id: id, in: &edit, mutate: mutate) else {
      return false
    }

    applyFeatureTreeEdit(edit)
    return true
  }

  private func applyFeatureTreeEdit(_ edit: Edit) {
    guard let current = loadedState?.currentEdit else {
      return
    }
    guard current != edit else {
      return
    }
    loadedState?.currentEdit = edit
  }
}
