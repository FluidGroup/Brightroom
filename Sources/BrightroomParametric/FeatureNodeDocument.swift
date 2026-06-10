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

/// A registry-backed parametric image editing document.
///
/// Unlike `EditingDocument`, this document stores all domain, effect, and mask
/// operations as `FeatureNode` values. Brightroom-provided features and
/// app-provided features therefore share the same serialized representation.
public struct FeatureDocument: Codable, Equatable, Sendable {

  /// The ordered main feature tree evaluated from source image to output image.
  public var mainTree: FeatureMainTree

  /// Creates a registry-backed editing document.
  public init(mainTree: FeatureMainTree = .init()) {
    self.mainTree = mainTree
  }
}

/// The main editing sequence for a registry-backed document.
public struct FeatureMainTree: Codable, Equatable, Sendable {

  /// The nodes evaluated in source-to-output order.
  public var features: [FeatureTreeNode]

  /// Creates a main tree with the provided ordered nodes.
  public init(features: [FeatureTreeNode] = []) {
    self.features = features
  }
}

/// A node that can appear in the registry-backed document's main tree.
public enum FeatureTreeNode: Codable, Equatable, Sendable {

  /// A feature node resolved as a domain-changing operation.
  case domain(FeatureNode)

  /// A feature node resolved as an extent-preserving image effect.
  case effect(FeatureNode)

  /// A local branch that composites an effect pipeline through a mask node.
  case localAdjustment(FeatureLocalAdjustment)
}

extension FeatureTreeNode: Feature {

  public var id: FeatureID {
    switch self {
    case let .domain(node):
      node.id
    case let .effect(node):
      node.id
    case let .localAdjustment(localAdjustment):
      localAdjustment.id
    }
  }

  public var isEnabled: Bool {
    switch self {
    case let .domain(node):
      node.isEnabled
    case let .effect(node):
      node.isEnabled
    case let .localAdjustment(localAdjustment):
      localAdjustment.isEnabled
    }
  }
}

/// An ordered chain of registry-backed extent-preserving effects.
public struct FeatureEffectPipeline: Codable, Equatable, Sendable {

  /// The effect nodes applied from first to last.
  public var effects: [FeatureNode]

  /// Creates an effect pipeline.
  public init(effects: [FeatureNode] = []) {
    self.effects = effects
  }
}

/// A registry-backed local adjustment branch.
public struct FeatureLocalAdjustment: Feature {

  /// The stable identity of this local adjustment.
  public var id: FeatureID

  /// A Boolean value indicating whether this local adjustment participates in rendering.
  public var isEnabled: Bool

  /// The root mask node that produces alpha for compositing.
  public var mask: FeatureNode

  /// The extent-preserving effects applied inside the local branch.
  public var effectPipeline: FeatureEffectPipeline

  /// The blend rule used to composite the adjusted branch over the base image.
  public var blendMode: LocalAdjustmentBlendMode

  /// Creates a registry-backed local adjustment branch.
  public init(
    id: FeatureID = .init(),
    isEnabled: Bool = true,
    mask: FeatureNode,
    effectPipeline: FeatureEffectPipeline,
    blendMode: LocalAdjustmentBlendMode = .alpha
  ) {
    self.id = id
    self.isEnabled = isEnabled
    self.mask = mask
    self.effectPipeline = effectPipeline
    self.blendMode = blendMode
  }
}
