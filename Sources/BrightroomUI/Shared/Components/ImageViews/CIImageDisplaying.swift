//
// Copyright (c) 2021 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
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

import UIKit

#if !COCOAPODS
import BrightroomEngine
#endif

public protocol CIImageDisplaying : class {
  func display(image: CIImage?)
  var postProcessing: (CIImage) -> CIImage { get set }
}

extension CIImageDisplaying {
  
  func downsample(image: CIImage, bounds: CGRect, contentMode: UIView.ContentMode) -> CIImage {
    
    let targetRect: CGRect
    
    switch contentMode {
    case .scaleAspectFill:
      targetRect = Geometry.rectThatAspectFill(
        aspectRatio: image.extent.size,
        minimumRect: bounds
      )
    case .scaleAspectFit:
      targetRect = Geometry.rectThatAspectFit(
        aspectRatio: image.extent.size,
        boundingRect: bounds
      )
    default:
      targetRect = Geometry.rectThatAspectFit(
        aspectRatio: image.extent.size,
        boundingRect: bounds
      )
      assertionFailure("ContentMode:\(contentMode) is not supported.")
    }
    
    let scaleX = targetRect.width / image.extent.width
    let scaleY = targetRect.height / image.extent.height
    let scale = min(scaleX, scaleY)
    
    let resolvedImage: CIImage
    
    #if targetEnvironment(simulator)
    // Fixes geometry in Metal
    resolvedImage = image
      .transformed(
        by: CGAffineTransform(scaleX: 1, y: -1)
          .concatenating(.init(translationX: 0, y: image.extent.height))
          .concatenating(.init(scaleX: scale, y: scale))
          .concatenating(.init(translationX: targetRect.origin.x, y: targetRect.origin.y))
      )
    
    #else
    resolvedImage = image
      .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
      .transformed(by: CGAffineTransform(translationX: targetRect.origin.x, y: targetRect.origin.y))
    
    #endif
    
    return resolvedImage
  }

  
}
