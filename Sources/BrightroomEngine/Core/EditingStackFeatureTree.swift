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

  /// The parameters of a single feature node.
  public typealias Payload = EditingFeature.Payload

  /// A feature node with a stable identity.
  public typealias Node = EditingFeature

  /// The features evaluated in source-to-output order.
  public private(set) var nodes: [Node]

  // MARK: - Well-known identities

  /// The identity of the global effects node.
  ///
  /// Present in every canonical document (created by `Edit.init(crop:)`), so
  /// UI can anchor editing affordances to a stable identity.
  public static let globalEffectsNodeID = EditingFeature.globalEffectsID

  /// The identity of the final crop node.
  public static let finalCropNodeID = EditingFeature.finalCropID

  /// The tree identity for a local adjustment layer.
  public static func nodeID(forLocalAdjustment id: UUID) -> FeatureID {
    EditingFeature.localAdjustmentID(for: id)
  }

  /// The local adjustment layer id encoded in a tree identity, if any.
  public static func localAdjustmentID(from nodeID: FeatureID) -> UUID? {
    EditingFeature.localAdjustmentLayerID(from: nodeID)
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

  /// The final crop feature.
  public var finalCrop: EditingCrop? {
    guard case let .crop(crop)? = node(id: Self.finalCropNodeID)?.payload else {
      return nil
    }
    return crop
  }

  /// The global effects feature.
  public var globalEffects: EditingStack.Edit.Filters? {
    guard case let .globalEffects(filters)? = node(id: Self.globalEffectsNodeID)?.payload else {
      return nil
    }
    return filters
  }

  /// The local adjustment nodes in evaluation order.
  public var localAdjustmentNodes: [Node] {
    nodes.filter {
      if case .localAdjustment = $0.payload {
        return true
      }
      return false
    }
  }

  /// The local adjustment layer addressed by a tree identity.
  public func localAdjustment(id: FeatureID) -> EditingStack.Edit.LocalAdjustmentLayer? {
    guard case let .localAdjustment(layer)? = node(id: id)?.payload else {
      return nil
    }
    return layer
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

  /// Applies a payload mutation to the node with `id` inside `edit`.
  ///
  /// The mutation must keep the payload kind stable. Returns false when the
  /// node does not exist or the mutation changed the payload kind.
  @discardableResult
  static func updateFeature(
    id: FeatureID,
    in edit: inout EditingStack.Edit,
    mutate: (inout Payload) -> Void
  ) -> Bool {
    edit.updateFeature(id: id, mutate: mutate)
  }

  /// Removes the feature with `id` from `edit`.
  ///
  /// Crop features are structural and not removable. Returns false when
  /// nothing was removed.
  @discardableResult
  static func removeFeature(
    id: FeatureID,
    from edit: inout EditingStack.Edit
  ) -> Bool {
    edit.removeFeature(id: id)
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
    mutate: (inout EditingFeatureTree.Payload) -> Void
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

  /// Mutates the global effects feature.
  public func updateGlobalEffectsFeature(
    _ mutate: (inout Edit.Filters) -> Void
  ) {
    updateFeature(id: EditingFeatureTree.globalEffectsNodeID) { payload in
      guard case var .globalEffects(filters) = payload else {
        return
      }
      mutate(&filters)
      payload = .globalEffects(filters)
    }
  }

  /// Appends a local adjustment feature before the final crop and returns its
  /// tree identity.
  @discardableResult
  public func appendFeature(
    localAdjustment layer: Edit.LocalAdjustmentLayer
  ) -> FeatureID {
    _pixelengine_ensureMainThread()

    let id = EditingFeature.localAdjustmentID(for: layer.id)
    guard var edit = loadedState?.currentEdit else {
      return id
    }
    edit.insertFeatureBeforeFinalCrop(.init(id: id, payload: .localAdjustment(layer)))
    loadedState?.currentEdit = edit
    return id
  }

  /// Removes the feature node with `id`.
  ///
  /// Crop features are structural and not removable; everything else is.
  /// Returns false when nothing was removed.
  @discardableResult
  public func removeFeature(id: FeatureID) -> Bool {
    _pixelengine_ensureMainThread()

    guard var edit = loadedState?.currentEdit else {
      return false
    }

    guard EditingFeatureTree.removeFeature(id: id, from: &edit) else {
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
