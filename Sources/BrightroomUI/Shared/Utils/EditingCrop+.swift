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
    imageSize
  }
  
  func calculateZoomScale(scrollViewSize: CGSize) -> (min: CGFloat, max: CGFloat) {
    let minXScale = scrollViewSize.width / imageSize.width
    let minYScale = scrollViewSize.height / imageSize.height
    
    /**
     max meaning scale aspect fill
     */
    let minScale = max(minXScale, minYScale)
        
    return (min: minScale, max: .greatestFiniteMagnitude)
  }
}
