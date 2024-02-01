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
    PixelAspectRatio(imageSize).size(byWidth: 1000)
  }
  
  func calculateZoomScale(scrollViewSize: CGSize) -> (min: CGFloat, max: CGFloat) {
    
    let size = scrollViewContentSize()
    let minXScale = scrollViewSize.width / size.width
    let minYScale = scrollViewSize.height / size.height

    /**
     max meaning scale aspect fill
     */
    let minScale = max(minXScale, minYScale)
        
    return (min: minScale, max: .greatestFiniteMagnitude)
  }
}
