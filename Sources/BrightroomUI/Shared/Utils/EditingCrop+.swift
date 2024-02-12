//
//  EditingCrop+.swift
//  PixelEditor
//
//  Created by Muukii on 2021/03/19.
//  Copyright © 2021 muukii. All rights reserved.
//

import Foundation
import CoreGraphics

#if !COCOAPODS
import BrightroomEngine
#endif

extension EditingCrop {
  func scrollViewContentSize() -> CGSize {
    // Use imageSize for masking view
//    imageSize
    PixelAspectRatio(imageSize).size(byWidth: 1000)
  }

  func scaleForDrawing() -> CGFloat {
    let scaleFromOriginal = Geometry.diagonalRatio(to: scrollViewContentSize(), from: imageSize)

    return scaleFromOriginal
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

  func zoomExtent(visibleSize: CGSize) -> CGRect {

    let contentSize = scrollViewContentSize()
    let cropExtent = cropExtent

    let scaleFromOriginal = Geometry.diagonalRatio(to: contentSize, from: imageSize)

    let _cropExtent = cropExtent.applying(.init(scaleX: scaleFromOriginal, y: scaleFromOriginal))

    return _cropExtent
  }

  func makeCropExtent(rect: CGRect) -> CGRect {

    let contentSize = scrollViewContentSize()
    let cropExtent = rect

    let scaleFromOriginal = Geometry.diagonalRatio(to: imageSize, from: contentSize)

    return cropExtent.applying(.init(scaleX: scaleFromOriginal, y: scaleFromOriginal))
  }

}
