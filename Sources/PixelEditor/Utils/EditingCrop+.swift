//
//  EditingCrop+.swift
//  PixelEditor
//
//  Created by Muukii on 2021/03/19.
//  Copyright © 2021 muukii. All rights reserved.
//

import Foundation

#if !COCOAPODS
import PixelEngine
#endif

extension EditingCrop {
  func scrollViewContentSize() -> CGSize {
    imageSize
  }
  
  func calculateZoomScale(scrollViewBounds: CGRect) -> (min: CGFloat, max: CGFloat) {
    let minXScale = scrollViewBounds.width / imageSize.width
    let minYScale = scrollViewBounds.height / imageSize.height
    
    /**
     max meaning scale aspect fill
     */
    let minScale = max(minXScale, minYScale)
    
    assert(minScale > 0)
    
    return (min: minScale, max: .greatestFiniteMagnitude)
  }
}
