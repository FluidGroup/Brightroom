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

/// The crop guide's working state, expressed in y-down image space after
/// straightening and before output rotation.
///
/// The stored crop (`CropFeature`) is dependency-free and authored in y-up Core
/// Image space; this is its UI working counterpart. It carries the oriented
/// image pixel size (sourced from the loaded state, since `CropFeature` has
/// none) so clamping and aspect-fitting work. Loading converts coordinates and
/// fits the selection to the source. Committing uses the engine's shared pixel
/// canonicalization before converting back to `CropFeature`; live gesture
/// coordinates remain continuous until then.
///
/// This is the home for the UI-authoring richness the engine does not carry:
/// the y-down selection, the active aspect-ratio session, and the output
/// quarter turn. It is internal: hosts see the crop only as a `CropFeature`
/// (`ImageEditorCanvas.CropGuide.pendingCrop` is `makeCropFeature()`).
struct CropGuideState: Equatable, Sendable {

  /// The oriented image pixel size, from the loaded state.
  var imageSize: CGSize

  /// The selection in y-down image pixels after straightening and before the
  /// output quarter turn. Changing `rotation` leaves this rectangle unchanged.
  /// Under straightening, this is not an axis-aligned source sampling footprint.
  private(set) var cropExtent: CGRect

  /// The quarter-turn rotation applied to the cropped output.
  var rotation: QuarterTurn = .zero

  /// The active aspect-ratio session in the final output orientation.
  private(set) var _usedAspectRatio: AspectRatio?

  /// A free straightening angle applied before cropping and output rotation.
  var adjustmentAngle: Angle = .zero

  /// The equivalent combined angle used by the live viewport.
  var aggregatedRotation: Angle {
    rotation.angle + adjustmentAngle
  }

  // MARK: - CropFeature coordinate adapters

  /// Builds the working model from a stored crop feature (y-up → y-down).
  init(cropFeature: CropFeature, imageSize: CGSize) {
    self.imageSize = imageSize
    // Containment uses the straightened selection, which may extend past the
    // unrotated image bounds while still sampling entirely inside the source.
    self.cropExtent = CropGeometry.fittingRect(
      rect: cropFeature.topLeftRect(imageSize: imageSize),
      in: imageSize,
      straightenRadians: cropFeature.straightenRadians,
      respectingAspectRatio: nil
    )
    self.rotation = cropFeature.quarterTurn
    self.adjustmentAngle = .radians(cropFeature.straightenRadians)
  }

  /// Creates a stored crop feature (y-down → y-up), using the pixel
  /// alignment of `CropFeature(topLeftRect:…)` for the selection before its
  /// output quarter turn.
  func makeCropFeature() -> CropFeature {
    CropFeature(
      topLeftRect: cropExtent,
      imageSize: imageSize,
      quarterTurn: rotation,
      straightenRadians: adjustmentAngle.radians
    )
  }

  // MARK: - Construction

  init(
    imageSize: CGSize,
    cropRect: CGRect,
    rotation: QuarterTurn = .zero,
    adjustmentAngle: Angle = .zero
  ) {
    self.imageSize = imageSize
    self.cropExtent = CropGeometry.fittingRect(
      rect: cropRect,
      in: imageSize,
      straightenRadians: adjustmentAngle.radians,
      respectingAspectRatio: nil
    )
    self.rotation = rotation
    self.adjustmentAngle = adjustmentAngle
  }

  /// A reset state: the full image extent with no rotation, straighten, or
  /// aspect lock — preserving the image size.
  func makeInitial() -> Self {
    .init(
      imageSize: imageSize,
      cropRect: .init(origin: .zero, size: imageSize)
    )
  }

  // MARK: - Mutations (geometry delegated to the engine's CropGeometry)

  /// Changes the output orientation while preserving the selected image area.
  ///
  /// Returns whether the output axes exchanged places. The active aspect ratio
  /// follows that exchange without fitting a new, larger selection.
  mutating func updateRotation(to newRotation: QuarterTurn) -> Bool {
    let swapsDimensions = rotation.isSideways != newRotation.isSideways
    if swapsDimensions {
      _usedAspectRatio = _usedAspectRatio?.swapped()
    }
    rotation = newRotation
    return swapsDimensions
  }

  /// Sets an output aspect ratio and fits a centered selection inside the image.
  /// The stored extent remains in the orientation before the output quarter turn.
  mutating func updateCropExtent(toFitAspectRatio newAspectRatio: AspectRatio) {
    self._usedAspectRatio = newAspectRatio
    let aspectRatio = aspectRatioBeforeOutputRotation(newAspectRatio)
    self.cropExtent = CropGeometry.cropRect(
      toFitAspectRatio: aspectRatio,
      in: imageSize,
      straightenRadians: adjustmentAngle.radians
    )
  }

  /// As `updateCropExtent(toFitAspectRatio:)`, but a no-op when the ratio is
  /// already active.
  mutating func updateCropExtentIfNeeded(toFitAspectRatio newAspectRatio: AspectRatio) {
    guard _usedAspectRatio != newAspectRatio else {
      return
    }
    updateCropExtent(toFitAspectRatio: newAspectRatio)
  }

  /// Whether the selection already has `aspectRatio` (in the final output
  /// orientation), allowing for the inward pixel snapping of
  /// `CropFeature(topLeftRect:…)`: each edge moves by less than a pixel, so
  /// a committed selection can miss the exact ratio by less than two pixels
  /// on its shorter-ratio side.
  func hasAspectRatio(_ aspectRatio: AspectRatio) -> Bool {
    let selectionRatio = aspectRatioBeforeOutputRotation(aspectRatio)
    let ratio = selectionRatio.width / selectionRatio.height
    guard ratio.isFinite, ratio > 0 else {
      return false
    }
    let mismatch = abs(cropExtent.width - ratio * cropExtent.height)
    return mismatch < 2 * max(1, ratio)
  }

  /// Starts an aspect-ratio session for a selection that was loaded rather
  /// than drawn under the lock (an undo, a reopened editor, a lock applied
  /// after loading). A selection that already has the ratio is kept as it
  /// is; otherwise the largest rectangle of the ratio is fitted inside it,
  /// about its center, rather than about the image's.
  mutating func adoptAspectRatio(_ newAspectRatio: AspectRatio) {
    _usedAspectRatio = newAspectRatio
    guard hasAspectRatio(newAspectRatio) == false else {
      return
    }
    let fitted = CropGeometry.fittingRect(
      rect: cropExtent,
      in: imageSize,
      straightenRadians: adjustmentAngle.radians,
      respectingAspectRatio: aspectRatioBeforeOutputRotation(newAspectRatio)
    )
    guard fitted.isNull == false, fitted.isEmpty == false else {
      updateCropExtent(toFitAspectRatio: newAspectRatio)
      return
    }
    cropExtent = fitted
  }

  mutating func purgeAspectRatio() {
    _usedAspectRatio = nil
  }

  /// Updates the crop extent to fit a normalized bounding box (e.g. from
  /// Vision), scaled by the selection's size before output rotation and anchored
  /// to the image origin. The optional aspect ratio describes the final output.
  mutating func updateCropExtent(
    toFitBoundingBox boundingBox: CGRect,
    respectingAspectRatio: AspectRatio?
  ) {
    self._usedAspectRatio = respectingAspectRatio
    self.cropExtent = CropGeometry.cropRect(
      toFitBoundingBox: boundingBox,
      within: cropExtent,
      in: imageSize,
      straightenRadians: adjustmentAngle.radians,
      respectingAspectRatio: respectingAspectRatio.map(aspectRatioBeforeOutputRotation)
    )
  }

  /// Replaces the selection in y-down pixels before output rotation.
  mutating func updateCropExtent(_ cropExtent: CGRect) {
    self.cropExtent = cropExtent
  }

  /// Converts an output aspect ratio into the stored selection's orientation.
  func aspectRatioBeforeOutputRotation(_ aspectRatio: AspectRatio) -> AspectRatio {
    rotation.isSideways ? aspectRatio.swapped() : aspectRatio
  }

  // MARK: - Rendering equivalence

  /// Whether two working states render identically, through
  /// `CropFeature.isPixelEquivalent(to:imageSize:)`. The UI uses this to decide whether a
  /// crop gesture actually changed the rendered result.
  func isPixelEquivalent(to other: CropGuideState) -> Bool {
    makeCropFeature().isPixelEquivalent(
      to: other.makeCropFeature(),
      imageSize: imageSize
    )
  }
}
