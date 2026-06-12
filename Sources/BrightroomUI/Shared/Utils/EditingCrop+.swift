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
extension EditingCrop {

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

  func calculateZoomScale(visibleSize: CGSize) -> (min: CGFloat, max: CGFloat) {

    let contentSize = scrollViewContentSize()
    let minXScale = visibleSize.width / contentSize.width
    let minYScale = visibleSize.height / contentSize.height

    /**
     max meaning scale aspect fill
     */
    let minScale = max(minXScale, minYScale)

    return (min: minScale, max: .greatestFiniteMagnitude)
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
