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
import SwiftUI

import BrightroomParametric

// MARK: - Edit → EditingDocument

extension EditingStack.Edit {

  /// Selects how much of the feature list a document covers.
  public enum DocumentSubset: Equatable, Sendable {

    /// Every feature, including the final crop — the export / final-result view.
    case full

    /// Every feature up to but excluding the final crop — the "viewing point"
    /// the canvas surface renders so the user can see outside the crop frame
    /// while adjusting the crop (per `docs/vision-of-editing.md`).
    case throughFinalCropExclusive
  }

  /// Lowers the editing document into the parametric `EditingDocument` evaluated
  /// by `ParametricImageRenderer`. This is the single bridge both export and
  /// preview use, so there is one evaluation path.
  ///
  /// - Parameter orientedImageSize: the oriented source pixel size (== `crop.imageSize`).
  ///   Crop rects snap against it, and pre-crop masks flip about its height.
  public func makeEditingDocument(orientedImageSize: CGSize) -> EditingDocument {
    makeEditingDocument(through: .full, orientedImageSize: orientedImageSize)
  }

  /// Lowers a subset of the document into a parametric `EditingDocument`.
  ///
  /// `Edit` already stores a parametric `EditingDocument`, so this is nearly the
  /// identity: effect nodes (the bundled `EffectPipelineFeature`, flattened by
  /// the compiler) and crop domain features pass through unchanged, and a local
  /// adjustment has its brush mask flipped from the engine's y-down authoring
  /// space into the compiler's y-up working space.
  public func makeEditingDocument(
    through subset: DocumentSubset,
    orientedImageSize: CGSize
  ) -> EditingDocument {

    let allFeatures = features
    let sourceFeatures: ArraySlice<MainFeature>
    switch subset {
    case .full:
      sourceFeatures = allFeatures[...]
    case .throughFinalCropExclusive:
      if let lastCropIndex = allFeatures.lastIndex(where: Self.isCropFeature) {
        sourceFeatures = allFeatures[..<lastCropIndex]
      } else {
        sourceFeatures = allFeatures[...]
      }
    }

    let mainFeatures = sourceFeatures.map { feature -> MainFeature in
      switch feature {
      case .localAdjustment(let adjustment):
        return .localAdjustment(
          adjustment.loweredToParametricDocument(domainHeight: orientedImageSize.height)
        )
      case .effect, .domain:
        return feature
      }
    }

    return EditingDocument(mainTree: MainTree(features: Array(mainFeatures)))
  }

  private static func isCropFeature(_ feature: MainFeature) -> Bool {
    if case let .domain(domain) = feature, domain is CropFeature {
      return true
    }
    return false
  }
}

// MARK: - Local adjustment mask space

extension LocalAdjustmentFeature {

  /// Returns a copy whose brush-mask stamps are flipped from the engine's
  /// y-down authoring space into the compiler's y-up working space.
  ///
  /// `EditingStack.Edit` stores brush stamps in oriented display coordinates
  /// (top-left origin, y-down); `FeatureGraphCompiler.renderMask` interprets
  /// stamps y-up. Flipping here lets the unified parametric path composite the
  /// adjustment in the same visual position the engine's CPU raster produced.
  func loweredToParametricDocument(domainHeight: CGFloat) -> LocalAdjustmentFeature {
    var copy = self
    copy.maskTree = MaskTree(root: maskTree.root.flippingStampsY(domainHeight: domainHeight))
    return copy
  }
}

extension MaskNode {

  /// Recursively flips brush-stroke stamp y-coordinates about `domainHeight`.
  /// Composite and refinement nodes carry no coordinates, so only their brush
  /// leaves change.
  func flippingStampsY(domainHeight: CGFloat) -> MaskNode {
    switch self {
    case .brush(var mask):
      mask.strokes = mask.strokes.map { stroke in
        var flipped = stroke
        flipped.stamps = stroke.stamps.map { CGPoint(x: $0.x, y: domainHeight - $0.y) }
        return flipped
      }
      return .brush(mask)

    case .invert(let node):
      return .invert(node.flippingStampsY(domainHeight: domainHeight))

    case .feather(var feather):
      feather.input = feather.input.flippingStampsY(domainHeight: domainHeight)
      return .feather(feather)

    case .union(let nodes):
      return .union(nodes.map { $0.flippingStampsY(domainHeight: domainHeight) })

    case .intersect(let nodes):
      return .intersect(nodes.map { $0.flippingStampsY(domainHeight: domainHeight) })

    case .subtract(var subtract):
      subtract.base = subtract.base.flippingStampsY(domainHeight: domainHeight)
      subtract.removing = subtract.removing.flippingStampsY(domainHeight: domainHeight)
      return .subtract(subtract)
    }
  }
}
