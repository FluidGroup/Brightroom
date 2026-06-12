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

/// A FeatureTree projection of `EditingStack.Edit`.
///
/// The tree is the contract between `EditingStack` and feature-editing UI
/// components: the UI previews the evaluated result at a `FeatureTreePoint`
/// and edits a feature node that may live at a different point.
///
/// Node order matches render order:
///
/// ```text
/// Source
///   -> globalEffects (Edit.Filters)
///   -> localAdjustment (each Edit.LocalAdjustmentLayer, in order)
///   -> crop (final EditingCrop)
///   -> Output
/// ```
///
/// The projection is derived data. Mutations go through
/// `EditingStack.updateFeature(id:mutate:)` and friends, which write back into
/// `EditingStack.Edit`; the tree itself never stores pixels or UI state.
public struct EditingFeatureTree: Equatable {

  /// The parameters of a single feature node.
  public enum Payload: Equatable {

    /// The global, extent-preserving filter chain evaluated first.
    case globalEffects(EditingStack.Edit.Filters)

    /// A masked local adjustment evaluated in the pre-final-crop domain.
    case localAdjustment(EditingStack.Edit.LocalAdjustmentLayer)

    /// The final framing/clipping crop.
    case crop(EditingCrop)
  }

  /// A feature node with a stable identity.
  public struct Node: Equatable, Identifiable {
    public let id: FeatureID
    public var payload: Payload

    public init(id: FeatureID, payload: Payload) {
      self.id = id
      self.payload = payload
    }
  }

  /// The features evaluated in source-to-output order.
  public private(set) var nodes: [Node]

  // MARK: - Well-known identities

  /// The identity of the global effects node.
  ///
  /// The node is always present, even when no filter is set, so UI can anchor
  /// editing affordances to a stable identity.
  public static let globalEffectsNodeID = FeatureID(
    rawValue: "brightroom.editing-stack.global-effects"
  )

  /// The identity of the final crop node.
  public static let finalCropNodeID = FeatureID(
    rawValue: "brightroom.editing-stack.final-crop"
  )

  private static let localAdjustmentNodeIDPrefix = "brightroom.editing-stack.local-adjustment."

  /// The tree identity for a local adjustment layer.
  public static func nodeID(forLocalAdjustment id: UUID) -> FeatureID {
    FeatureID(rawValue: localAdjustmentNodeIDPrefix + id.uuidString)
  }

  /// The local adjustment layer id encoded in a tree identity, if any.
  public static func localAdjustmentID(from nodeID: FeatureID) -> UUID? {
    guard nodeID.rawValue.hasPrefix(localAdjustmentNodeIDPrefix) else {
      return nil
    }

    return UUID(uuidString: String(nodeID.rawValue.dropFirst(localAdjustmentNodeIDPrefix.count)))
  }

  // MARK: - Projection

  /// Projects an `EditingStack.Edit` into the feature tree.
  public init(edit: EditingStack.Edit) {
    var nodes: [Node] = []
    nodes.reserveCapacity(edit.localAdjustments.count + 2)

    nodes.append(
      .init(id: Self.globalEffectsNodeID, payload: .globalEffects(edit.filters))
    )

    for layer in edit.localAdjustments {
      nodes.append(
        .init(id: Self.nodeID(forLocalAdjustment: layer.id), payload: .localAdjustment(layer))
      )
    }

    nodes.append(
      .init(id: Self.finalCropNodeID, payload: .crop(edit.crop))
    )

    self.nodes = nodes
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
  /// The mutation must keep the payload kind stable; switching a crop node to a
  /// local adjustment is rejected. Returns false when the node does not exist
  /// or the mutation changed the payload kind.
  @discardableResult
  static func updateFeature(
    id: FeatureID,
    in edit: inout EditingStack.Edit,
    mutate: (inout Payload) -> Void
  ) -> Bool {
    let tree = EditingFeatureTree(edit: edit)
    guard let node = tree.node(id: id) else {
      return false
    }

    var payload = node.payload
    mutate(&payload)

    switch (node.payload, payload) {
    case (.globalEffects, let .globalEffects(filters)):
      edit.filters = filters
      return true

    case (.localAdjustment(let previousLayer), let .localAdjustment(layer)):
      guard
        let index = edit.localAdjustments.firstIndex(where: { $0.id == previousLayer.id })
      else {
        return false
      }
      edit.localAdjustments[index] = layer
      return true

    case (.crop, let .crop(crop)):
      edit.crop = crop
      return true

    default:
      assertionFailure("updateFeature must not change the payload kind of \(id.rawValue)")
      return false
    }
  }

  /// Removes the feature with `id` from `edit`.
  ///
  /// Only local adjustment nodes are removable; global effects and the final
  /// crop are structural. Returns false when nothing was removed.
  @discardableResult
  static func removeFeature(
    id: FeatureID,
    from edit: inout EditingStack.Edit
  ) -> Bool {
    guard let layerID = localAdjustmentID(from: id) else {
      return false
    }

    let previousCount = edit.localAdjustments.count
    edit.localAdjustments.removeAll(where: { $0.id == layerID })
    return edit.localAdjustments.count != previousCount
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

  /// Appends a local adjustment feature and returns its tree identity.
  @discardableResult
  public func appendFeature(
    localAdjustment layer: Edit.LocalAdjustmentLayer
  ) -> FeatureID {
    append(localAdjustment: layer)
    return EditingFeatureTree.nodeID(forLocalAdjustment: layer.id)
  }

  /// Removes the feature node with `id`.
  ///
  /// Only local adjustment nodes are removable. Returns false when nothing was
  /// removed.
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

    if current.filters != edit.filters {
      set(filters: { $0 = edit.filters })
    }
    if current.localAdjustments != edit.localAdjustments {
      set(localAdjustments: edit.localAdjustments)
    }
    if current.crop != edit.crop {
      crop(edit.crop)
    }
  }
}
