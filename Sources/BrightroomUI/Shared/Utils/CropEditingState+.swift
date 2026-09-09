//
//  EditingCrop+.swift
//  PixelEditor
//
//  Created by Muukii on 2021/03/19.
//  Copyright © 2021 muukii. All rights reserved.
//

import Foundation
import CoreGraphics

import BrightroomEngine

/// Image <-> platter conversions for the crop scroll view.
///
/// The "platter" is the normalized content the scroll view hosts: width fixed
/// at 1000pt, height preserving the image aspect ratio exactly. Every
/// conversion below derives from the single `imageToPlatterScale()` scalar so
/// recorded crop extents and rendered viewports can never disagree about the
/// mapping.
extension CropEditingState {

  /// The smallest crop-output side the crop surface may author, in image pixels.
  ///
  /// The masking tool treats the final crop output as its editable canvas. Letting
  /// crop zoom create a smaller output forces the tool surface into very large
  /// zoom scales and resolves viewport-sized brushes into sub-pixel image-space
  /// strokes, which is not a meaningful blur-mask editing domain.
  static let minimumAuthoredCropOutputSideLength: CGFloat = 128

  func scrollViewContentSize() -> CGSize {
    PixelAspectRatio(imageSize).size(byWidth: 1000)
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

  /// Returns the crop scroll view's zoom range for a visible crop guide size.
  ///
  /// `max` is finite by design: the crop output becomes the masking tool's
  /// canvas, so crop authoring must stop before that output becomes too small to
  /// paint with a viewport-sized brush reliably.
  func calculateZoomScale(visibleSize: CGSize) -> (min: CGFloat, max: CGFloat) {

    let contentSize = scrollViewContentSize()
    let minXScale = visibleSize.width / contentSize.width
    let minYScale = visibleSize.height / contentSize.height

    /**
     max meaning scale aspect fill
     */
    let minScale = max(minXScale, minYScale)

    let platterScale = imageToPlatterScale()
    let effectiveMinimumOutputSide = min(
      Self.minimumAuthoredCropOutputSideLength,
      max(min(imageSize.width, imageSize.height), 1)
    )
    let minimumPlatterSide = effectiveMinimumOutputSide * platterScale
    let maxScale = min(
      visibleSize.width / max(minimumPlatterSide, 0.0001),
      visibleSize.height / max(minimumPlatterSide, 0.0001)
    )

    return (min: minScale, max: max(minScale, maxScale))
  }

  func platterRect(fromImageRect rect: CGRect) -> CGRect {
    let scale = imageToPlatterScale()
    return rect.applying(.init(scaleX: scale, y: scale))
  }

  func imageRect(fromPlatterRect rect: CGRect) -> CGRect {
    let scale = 1 / imageToPlatterScale()
    return rect.applying(.init(scaleX: scale, y: scale))
  }

  /// The crop extent expressed in platter coordinates.
  func zoomExtent() -> CGRect {
    platterRect(fromImageRect: cropExtent)
  }

  /// Converts a platter-coordinate rect into an image-coordinate crop extent.
  func makeCropExtent(rect: CGRect) -> CGRect {
    imageRect(fromPlatterRect: rect)
  }
}
