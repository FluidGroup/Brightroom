//
// Copyright (c) 2018 Muukii <muukii.app@gmail.com>
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

import CoreImage
import Verge

#if canImport(UIKit)
import UIKit
#endif

#if canImport(Photos)
import Photos
#endif


/**
 An object that provides an image-data from multiple backing storage.
 */
public final class ImageSource: Equatable {
        
  private struct Closures {
    let readImageSize: () -> CGSize
    let loadOriginalCGImage: () -> CGImage
    let loadThumbnailCGImage: (CGFloat) -> CGImage
    let makeCIImage: () -> CIImage
  }
  
  public static func == (lhs: ImageSource, rhs: ImageSource) -> Bool {
    lhs === rhs
  }
  
  private let closures: Closures
  
  public init(image: UIImage) {
  
    self.closures = .init(
      readImageSize: {
        image.size.applying(.init(scaleX: image.scale, y: image.scale))
      },
      loadOriginalCGImage: {
        image.cgImage!
      },
      loadThumbnailCGImage: { (maxPixelSize) -> CGImage in
        return ImageTool.makeResizedCGImage(maxPixelSize: maxPixelSize, from: image.cgImage!)!
      },
      makeCIImage: {
        CIImage(image: image)!
      }
    )
  }
  
  public init(cgImageSource: CGImageSource) {
    self.closures = .init(
      readImageSize: {
        ImageTool.readImageSize(from: cgImageSource)!
      },
      loadOriginalCGImage: {
        ImageTool.loadOriginalCGImage(from: cgImageSource)!
      },
      loadThumbnailCGImage: { (maxPixelSize) -> CGImage in
        ImageTool.loadThumbnailCGImage(from: cgImageSource, maxPixelSize: maxPixelSize)!
      },
      makeCIImage: {
        if #available(iOS 13.0, *) {
          return CIImage(cgImageSource: cgImageSource, index: 0, options: [:])
        } else {
          return CIImage(cgImage: ImageTool.loadOriginalCGImage(from: cgImageSource)!)
        }
      }
    )
  }
  
  public func readImageSize() -> CGSize {
    closures.readImageSize()
  }
  
  public func loadOriginalCGImage() -> CGImage {
    closures.loadOriginalCGImage()
  }
  
  public func loadThumbnailCGImage(maxPixelSize: CGFloat) -> CGImage {
    closures.loadThumbnailCGImage(maxPixelSize)
  }
  
  public func makeCIImage() -> CIImage {
    closures.makeCIImage()
  }
      
}

