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

  /// Lowers a subset of the feature list into a parametric `EditingDocument`.
  ///
  /// The mapping is order-preserving: an effects pipeline expands into one
  /// `.effect` per effect, a local adjustment passes through (with its brush
  /// mask flipped into the compiler's y-up space), and a crop becomes a
  /// `.domain(CropFeature)` whose geometry matches the engine's `RenderCrop`.
  public func makeEditingDocument(
    through subset: DocumentSubset,
    orientedImageSize: CGSize
  ) -> EditingDocument {

    let sourceFeatures: ArraySlice<EditingFeature>
    switch subset {
    case .full:
      sourceFeatures = features[...]
    case .throughFinalCropExclusive:
      if let lastCropIndex = features.lastIndex(where: { $0.payload.kind == .crop }) {
        sourceFeatures = features[..<lastCropIndex]
      } else {
        sourceFeatures = features[...]
      }
    }

    var mainFeatures: [MainFeature] = []
    for feature in sourceFeatures {
      switch feature.payload {
      case .effects(let pipeline):
        // Expand the pipeline into individual main-tree effects so document
        // order is preserved across interleaved effects/adjustments. The
        // compiler skips disabled features, so no pre-filter is needed.
        mainFeatures.append(contentsOf: pipeline.effects.map { MainFeature.effect($0) })

      case .localAdjustment(let adjustment):
        mainFeatures.append(
          .localAdjustment(
            adjustment.loweredToParametricDocument(domainHeight: orientedImageSize.height)
          )
        )

      case .crop(let crop):
        mainFeatures.append(
          .domain(crop.parametricCropFeature(id: feature.id, orientedImageSize: orientedImageSize))
        )
      }
    }

    return EditingDocument(mainTree: MainTree(features: mainFeatures))
  }
}

// MARK: - EditingCrop → CropFeature

extension QuarterTurn {

  /// Maps the engine's quarter-turn rotation. The signed-degree raw values
  /// match `EditingCrop.Rotation.angle`, so the sign convention is preserved.
  init(engine rotation: EditingCrop.Rotation) {
    switch rotation {
    case .angle_0: self = .zero
    case .angle_90: self = .quarterCW
    case .angle_180: self = .half
    case .angle_270: self = .quarterCCW
    }
  }
}

extension EditingCrop {

  /// Lowers the engine crop into a pure parametric crop feature.
  ///
  /// The crop rect is snapped to the engine's inward-integer pixel contract
  /// (`RenderCrop`/`PixelCropRect`) so the materialized extent matches the
  /// legacy `croppedWithColorspace` output, and flipped from the engine's
  /// y-down display space into the compiler's y-up working space. Rotation and
  /// the free straighten angle carry over and are applied about the crop center
  /// by `CropFeature.apply`.
  func parametricCropFeature(id: FeatureID, orientedImageSize: CGSize) -> CropFeature {
    let renderCrop = RenderCrop(self, imageSize: orientedImageSize)
    let snapped = renderCrop.cropRect
    let imageHeight = CGFloat(renderCrop.imageSize.height)

    let ciCropRect = CGRect(
      x: CGFloat(snapped.x),
      y: imageHeight - CGFloat(snapped.y) - CGFloat(snapped.height),
      width: CGFloat(snapped.width),
      height: CGFloat(snapped.height)
    )

    return CropFeature(
      id: id,
      isEnabled: true,
      cropRect: ciCropRect,
      rotation: QuarterTurn(engine: rotation),
      straightenRadians: adjustmentAngle.radians
    )
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

// MARK: - CoreGraphics fast-path support

extension EditingDocument {

  /// The single crop feature when the document reduces to an axis-aligned crop
  /// with no other enabled feature — the case the CoreGraphics fast path can
  /// render without a `CIContext`. Returns nil when any effect/adjustment is
  /// enabled or the crop carries rotation/straighten.
  var axisAlignedCropOnlyFeature: CropFeature? {
    let enabled = mainTree.features.filter(\.isEnabled)
    guard
      enabled.count == 1,
      case let .domain(domain) = enabled[0],
      let crop = domain as? CropFeature,
      crop.rotation == .zero,
      crop.straightenRadians == 0
    else {
      return nil
    }
    return crop
  }
}

extension CropFeature {

  /// The crop rect as the engine's y-down integer pixel rect — the inverse of
  /// the bridge's y-up flip. Only meaningful for axis-aligned (no rotation)
  /// crops; used by the CoreGraphics fast path.
  func pixelCropRect(orientedImageHeight: CGFloat) -> PixelCropRect {
    PixelCropRect(
      x: Int(cropRect.minX.rounded()),
      y: Int((orientedImageHeight - cropRect.maxY).rounded()),
      width: max(1, Int(cropRect.width.rounded())),
      height: max(1, Int(cropRect.height.rounded()))
    )
  }
}
