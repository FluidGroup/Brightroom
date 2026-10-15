//
//  CropGuideState+Geometry.swift
//  BrightroomUI
//
//  Created by Muukii on 2021/03/19.
//  Copyright © 2021 muukii. All rights reserved.
//

import Foundation
import CoreGraphics

import BrightroomEngine
import BrightroomParametric

/// Image <-> platter conversions for the crop scroll view.
///
/// The "platter" is the normalized content the scroll view hosts: width fixed
/// at 1000pt, height preserving the image aspect ratio exactly. Pixel-to-point
/// conversions use the single `imageToPlatterScale()` scalar. Guide layout and
/// gesture readback also account for the crop's output orientation.
extension CropGuideState {

  /// The viewport crop rectangle, with the output's size about the image-space
  /// selection center. This derived rectangle is only used to lay out the guide
  /// and read back viewport interactions; `cropExtent` stays before output rotation.
  var outputCropExtent: CGRect {
    CropGeometry.rect(cropExtent, turnedBy: rotation)
  }

  /// The smallest crop-output side the crop surface may author, in image pixels.
  ///
  /// The masking tool treats the final crop output as its editable canvas. Letting
  /// crop zoom create a smaller output forces the tool surface into very large
  /// zoom scales and resolves viewport-sized brushes into sub-pixel image-space
  /// strokes, which is not a meaningful blur-mask editing domain.
  static let minimumAuthoredCropOutputSideLength: CGFloat = 128

  /// The smallest crop-output side the editor gives a crop of an image of
  /// `imageSize`: `minimumAuthoredCropOutputSideLength`, or the image's
  /// shorter side when that is smaller.
  static func minimumCropOutputSideLength(imageSize: CGSize) -> CGFloat {
    min(
      minimumAuthoredCropOutputSideLength,
      max(min(imageSize.width, imageSize.height), 1)
    )
  }

  func scrollViewContentSize() -> CGSize {
    AspectRatio(imageSize).size(byWidth: 1000)
  }

  /// The uniform image -> platter scale.
  ///
  /// `scrollViewContentSize()` preserves the aspect ratio exactly, so
  /// per-axis and diagonal ratios agree; one scalar is the whole contract.
  func imageToPlatterScale() -> CGFloat {
    scrollViewContentSize().width / max(imageSize.width, 1)
  }

  func scaleForDrawing() -> CGFloat {
    imageToPlatterScale()
  }

  /// Returns the crop scroll view's zoom range for a crop guide of
  /// `guideSize`, whose bounding box after the aggregated rotation is
  /// `visibleSize`.
  ///
  /// `min` makes the image cover `visibleSize`. `max` is finite by design:
  /// the crop output becomes the masking tool's canvas, so crop authoring
  /// must stop before that output becomes too small to paint with a
  /// viewport-sized brush reliably. At `max`, the guide's own shorter side
  /// shows `minimumCropOutputSideLength(imageSize:)` pixels; the bounding
  /// box of a straightened guide is larger than the guide, so it would
  /// let the guide show less. Under an aspect-ratio session whose lowest
  /// terms are both at most 32, it shows the smallest whole multiple of
  /// the shorter term that reaches that (135 for 16:9), the smallest crop
  /// a record writes, so a zoom to the maximum does not grow when it
  /// settles.
  func calculateZoomScale(visibleSize: CGSize, guideSize: CGSize) -> (min: CGFloat, max: CGFloat) {

    let contentSize = scrollViewContentSize()
    let minXScale = visibleSize.width / contentSize.width
    let minYScale = visibleSize.height / contentSize.height

    /**
     max meaning scale aspect fill
     */
    let minScale = max(minXScale, minYScale)

    let platterScale = imageToPlatterScale()
    // Under an aspect-ratio session, the smallest crop the record keeps:
    // a 16:9 crop is written in whole multiples of 16 × 9, so 135 rather
    // than 128 (`CropGeometry.rectEnlarged(toMinimumSide:…)`).
    let effectiveMinimumOutputSide = CropGeometry.smallestShorterSide(
      reaching: Self.minimumCropOutputSideLength(imageSize: imageSize),
      aspectRatio: _usedAspectRatio
    )
    let minimumPlatterSide = effectiveMinimumOutputSide * platterScale
    let maxScale = min(guideSize.width, guideSize.height) / max(minimumPlatterSide, 0.0001)

    return (min: minScale, max: max(minScale, maxScale))
  }

  /// The zoom scale at which the crop fills a guide of `guideSize`, as the
  /// crop scroll view zooms to it; 0 when the crop has no area.
  func zoomScaleFilling(guideSize: CGSize) -> CGFloat {
    let extent = zoomExtent()
    let scale = min(guideSize.width / extent.width, guideSize.height / extent.height)
    return scale.isFinite && scale > 0 ? scale : 0
  }

  /// The crop scroll view's zoom range for this crop in a guide of
  /// `guideSize`, whose bounding box after the aggregated rotation is
  /// `visibleSize`.
  ///
  /// It is `calculateZoomScale(visibleSize:guideSize:)`, except that the
  /// maximum is raised to `zoomScaleFilling(guideSize:)` when the crop is
  /// smaller than the maximum zoom shows. Such a crop is under the editor's minimum size
  /// (`minimumCropOutputSideLength(imageSize:)`), for example one a host
  /// set; the guide then shows exactly the crop rather than the larger area
  /// around it. Only the crop's next record enlarges it, so loading it
  /// writes nothing. Any other crop gets the usual range.
  func zoomScaleRange(visibleSize: CGSize, guideSize: CGSize) -> (min: CGFloat, max: CGFloat) {
    let range = calculateZoomScale(visibleSize: visibleSize, guideSize: guideSize)
    return (min: range.min, max: max(range.max, zoomScaleFilling(guideSize: guideSize)))
  }

  func platterRect(fromImageRect rect: CGRect) -> CGRect {
    let scale = imageToPlatterScale()
    return rect.applying(.init(scaleX: scale, y: scale))
  }

  func imageRect(fromPlatterRect rect: CGRect) -> CGRect {
    let scale = 1 / imageToPlatterScale()
    return rect.applying(.init(scaleX: scale, y: scale))
  }

  /// The output-oriented crop extent expressed in platter coordinates.
  func zoomExtent() -> CGRect {
    platterRect(fromImageRect: outputCropExtent)
  }

  /// Converts an output-oriented platter rect into the stored pre-turn extent.
  func makeCropExtent(rect: CGRect) -> CGRect {
    CropGeometry.rect(imageRect(fromPlatterRect: rect), turnedBy: rotation)
  }
}
