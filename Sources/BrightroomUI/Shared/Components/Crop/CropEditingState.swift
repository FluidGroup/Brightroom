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
/// image space after straightening and before output rotation.
///
/// The stored crop (`CropFeature`) is dependency-free and authored in y-up Core
/// Image space; this is its UI working counterpart. It carries the oriented
/// image pixel size (sourced from the loaded state, since `CropFeature` has
/// none) so clamping and aspect-fitting work. Loading converts coordinates and
/// fits the selection to the source. Committing uses the engine's shared pixel
/// canonicalization before converting back to `CropFeature`; live gesture
/// coordinates remain continuous until then.
///
/// This is the home for the UI-authoring richness the engine no longer carries:
/// the y-down selection, the active aspect-ratio session, and the rotation
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

  /// The selection in y-down image pixels after straightening and before the
  /// output quarter turn. Changing `rotation` leaves this rectangle unchanged.
  /// Under straightening, this is not an axis-aligned source sampling footprint.
  public private(set) var cropExtent: CGRect

  /// The quarter-turn rotation applied to the cropped output.
  public var rotation: Rotation = .angle_0

  /// The active aspect-ratio session in the final output orientation.
  public private(set) var _usedAspectRatio: PixelAspectRatio?

  /// A free straightening angle applied before cropping and output rotation.
  public var adjustmentAngle: AdjustmentAngle = .zero

  /// The equivalent combined angle used by the live viewport.
  public var aggregatedRotation: AdjustmentAngle {
    rotation.angle + adjustmentAngle
  }

  // MARK: - CropFeature coordinate adapters

  /// Builds the working model from a stored crop feature (y-up → y-down).
  public init(cropFeature: CropFeature, imageSize: CGSize) {
    self.id = cropFeature.id
    self.imageSize = imageSize
    // Containment uses the straightened selection, which may extend past the
    // unrotated image bounds while still sampling entirely inside the source.
    self.cropExtent = CropGeometry.fittingRect(
      rect: cropFeature.displayCropRect(imageSize: imageSize),
      in: imageSize,
      straightenRadians: cropFeature.straightenRadians,
      respectingAspectRatio: nil
    )
    self.rotation = Rotation(cropFeature.rotation)
    self.adjustmentAngle = .radians(cropFeature.straightenRadians)
  }

  /// Creates a stored crop feature (y-down → y-up), using the engine's pixel
  /// canonicalization for the selection before its output quarter turn.
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
      straightenRadians: adjustmentAngle.radians,
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

  /// Changes the output orientation while preserving the selected image area.
  ///
  /// Returns whether the output axes exchanged places. The active aspect ratio
  /// follows that exchange without fitting a new, larger selection.
  mutating func updateRotation(to newRotation: Rotation) -> Bool {
    let swapsDimensions = rotation.quarterTurn.isSideways != newRotation.quarterTurn.isSideways
    if swapsDimensions {
      _usedAspectRatio = _usedAspectRatio?.swapped()
    }
    rotation = newRotation
    return swapsDimensions
  }

  /// Sets an output aspect ratio and fits a centered selection inside the image.
  /// The stored extent remains in the orientation before the output quarter turn.
  public mutating func updateCropExtent(toFitAspectRatio newAspectRatio: PixelAspectRatio) {
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
  /// Vision), scaled by the selection's size before output rotation and anchored
  /// to the image origin. The optional aspect ratio describes the final output.
  public mutating func updateCropExtent(
    toFitBoundingBox boundingBox: CGRect,
    respectingApectRatio: PixelAspectRatio?
  ) {
    self._usedAspectRatio = respectingApectRatio
    self.cropExtent = CropGeometry.cropRect(
      toFitBoundingBox: boundingBox,
      within: cropExtent,
      in: imageSize,
      straightenRadians: adjustmentAngle.radians,
      respectingAspectRatio: respectingApectRatio.map(aspectRatioBeforeOutputRotation)
    )
  }

  /// Replaces the selection in y-down pixels before output rotation.
  public mutating func updateCropExtent(_ cropExtent: CGRect) {
    self.cropExtent = cropExtent
  }

  /// Converts an output aspect ratio into the stored selection's orientation.
  func aspectRatioBeforeOutputRotation(_ aspectRatio: PixelAspectRatio) -> PixelAspectRatio {
    rotation.quarterTurn.isSideways ? aspectRatio.swapped() : aspectRatio
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
