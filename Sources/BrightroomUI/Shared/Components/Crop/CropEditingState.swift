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
import SwiftUI

import BrightroomEngine
import BrightroomParametric

/// BrightroomUI's mutable crop-editing working model, expressed in y-down
/// display (gesture) space.
///
/// The stored crop (`CropFeature`) is dependency-free and authored in y-up Core
/// Image space; this is its gesture-space counterpart. It carries the oriented
/// image pixel size (sourced from the loaded state, since `CropFeature` has
/// none) so clamping and aspect-fitting work, and converts to and from
/// `CropFeature` through the engine's shared integer-snap helper at load and
/// commit — so the live viewport and the stored document never disagree about
/// the crop rect.
///
/// This is the home for the UI-authoring richness the engine no longer carries:
/// the y-down gesture extent, the active aspect-ratio session, and the rotation
/// in `CropRotation`.
public struct CropEditingState: Equatable, Sendable {

  public typealias Rotation = CropRotation
  public typealias AdjustmentAngle = SwiftUI.Angle

  /// The identity of the crop feature this state edits (preserved across the
  /// load → mutate → commit round trip so the document's final-crop node keeps
  /// its stable id).
  public var id: FeatureID

  /// The oriented image pixel size, from the loaded state.
  public var imageSize: CGSize

  /// The crop extent in y-down display space (top-left origin).
  public private(set) var cropExtent: CGRect

  /// The quarter-turn rotation applied to the crop.
  public var rotation: Rotation = .angle_0

  /// The active aspect-ratio session, if a ratio is locked.
  public private(set) var _usedAspectRatio: PixelAspectRatio?

  /// A free straightening angle applied in addition to `rotation`.
  public var adjustmentAngle: AdjustmentAngle = .zero

  /// The combined rotation (quarter turn + straighten).
  public var aggregatedRotation: AdjustmentAngle {
    rotation.angle + adjustmentAngle
  }

  // MARK: - CropFeature adapters (the single y-flip boundary)

  /// Builds the working model from a stored crop feature (y-up → y-down).
  public init(cropFeature: CropFeature, imageSize: CGSize) {
    self.id = cropFeature.id
    self.imageSize = imageSize
    self.cropExtent = CropGeometry.fittingRect(
      rect: cropFeature.displayCropRect(imageSize: imageSize),
      in: imageSize,
      respectingAspectRatio: nil
    )
    self.rotation = Rotation(cropFeature.rotation)
    self.adjustmentAngle = .radians(cropFeature.straightenRadians)
  }

  /// Lowers the working model into a stored crop feature (y-down → y-up),
  /// reusing the engine's integer pixel-snap (`CropFeature(displayCropRect:…)`)
  /// so the committed crop and the live viewport agree. Authoring an independent
  /// snapper here makes `isRenderingEquivalent` oscillate and the crop jitter.
  public func makeCropFeature() -> CropFeature {
    CropFeature(
      id: id,
      displayCropRect: cropExtent,
      imageSize: imageSize,
      rotation: rotation.quarterTurn,
      straighten: adjustmentAngle.radians
    )
  }

  // MARK: - Construction

  init(
    id: FeatureID,
    imageSize: CGSize,
    cropRect: CGRect,
    rotation: Rotation = .angle_0,
    adjustmentAngle: AdjustmentAngle = .zero
  ) {
    self.id = id
    self.imageSize = imageSize
    self.cropExtent = CropGeometry.fittingRect(
      rect: cropRect,
      in: imageSize,
      respectingAspectRatio: nil
    )
    self.rotation = rotation
    self.adjustmentAngle = adjustmentAngle
  }

  /// A reset state: the full image extent with no rotation, straighten, or
  /// aspect lock — preserving the crop identity and image size.
  public func makeInitial() -> Self {
    .init(
      id: id,
      imageSize: imageSize,
      cropRect: .init(origin: .zero, size: imageSize)
    )
  }

  // MARK: - Mutations (geometry delegated to the engine's CropGeometry)

  /// Set a new aspect ratio, updating the cropping extent to the maximum size
  /// of that ratio inside the image.
  public mutating func updateCropExtent(toFitAspectRatio newAspectRatio: PixelAspectRatio) {
    self._usedAspectRatio = newAspectRatio
    self.cropExtent = CropGeometry.cropRect(toFitAspectRatio: newAspectRatio, in: imageSize)
  }

  /// As `updateCropExtent(toFitAspectRatio:)`, but a no-op when the ratio is
  /// already active.
  public mutating func updateCropExtentIfNeeded(toFitAspectRatio newAspectRatio: PixelAspectRatio) {
    guard _usedAspectRatio != newAspectRatio else {
      return
    }
    updateCropExtent(toFitAspectRatio: newAspectRatio)
  }

  public mutating func purgeAspectRatio() {
    _usedAspectRatio = nil
  }

  /// Updates the crop extent to fit a normalized bounding box (e.g. from
  /// Vision), optionally constrained to an aspect ratio.
  public mutating func updateCropExtent(
    toFitBoundingBox boundingBox: CGRect,
    respectingApectRatio: PixelAspectRatio?
  ) {
    self._usedAspectRatio = respectingApectRatio
    self.cropExtent = CropGeometry.cropRect(
      toFitBoundingBox: boundingBox,
      within: cropExtent,
      in: imageSize,
      respectingAspectRatio: respectingApectRatio
    )
  }

  public mutating func updateCropExtent(_ cropExtent: CGRect) {
    self.cropExtent = cropExtent
  }

  // MARK: - Rendering equivalence

  /// Whether two working states render identically, through the engine's
  /// integer pixel-snap crop equivalence. The UI uses this to decide whether a
  /// crop gesture actually changed the rendered result.
  public func isRenderingEquivalent(to other: CropEditingState) -> Bool {
    makeCropFeature().isRenderingEquivalent(
      to: other.makeCropFeature(),
      orientedImageSize: imageSize
    )
  }
}
