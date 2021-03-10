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

import CoreImage
import UIKit

public final class ImageRenderer {
  
  private static let queue = DispatchQueue.init(label: "app.muukii.Pixel.renderer")
  
  public enum Resolution {
    case full
    case resize(boundingSize: CGSize)
  }

  public struct Edit {
    public var croppingRect: EditingCrop?
    public var modifiers: [Filtering] = []
    public var drawer: [GraphicsDrawing] = []
  }

  private let cicontext = CIContext(options: [
    .useSoftwareRenderer : false,
    .highQualityDownsample : true,
    ])
  
  public let source: CIImage

  public var edit: Edit

  public init(source: CIImage) {
    self.source = source
    self.edit = .init()
  }
  
  public func asyncRender(resolution: Resolution = .full, completion: @escaping (UIImage) -> Void) {
    type(of: self).queue.async {
      let image = self.render()
      DispatchQueue.main.async {
        completion(image)
      }
    }
  }
  
  /**
   Renders an image according to the editing.
   
   - Attension: This operation can be run background-thread.
   */
  public func render(resolution: Resolution = .full) -> UIImage {
    
    assert(
      {
        guard let crop = edit.croppingRect else { return true }
        return crop.imageSize == CGSize(image: source)
      }())
    
    let croppedImage: CIImage = {

      let sourceImage: CIImage
      
      if let crop = edit.croppingRect {
        
        /**
         The reason why here does transformed in pre and post:
         Core Image's coordinate system mismatches with UIKIt.
         Zero-point is bottom-left and UIKit's zero-point is top-left.
         To solve this mismatch while cropping, flips and crops and finally flips.
         */
        
        sourceImage = source          
          /* pre */
          .transformed(by: .init(scaleX: 1, y: -1))
          .transformed(by: .init(translationX: 0, y: source.extent.height))
          
          /* apply */
          .cropped(to: crop.cropExtent)
          .transformed(by: crop.rotation.transform)
          
          /* post */
          .transformed(by: .init(scaleX: 1, y: -1))
          .transformed(by: .init(translationX: 0, y: source.extent.height))
      } else {
        sourceImage = source
      }

      let result = edit.modifiers.reduce(sourceImage, { image, modifier in
        return modifier.apply(to: image, sourceImage: sourceImage)
      })

      return result

    }()
    
    EngineLog.debug("Source.colorSpace :", source.colorSpace as Any)

    var canvasSize: CGSize
      
    switch resolution {
    case .full:
      canvasSize = croppedImage.extent.size
    case .resize(let boundingSize):
      canvasSize = Geometry.sizeThatAspectFit(aspectRatio: croppedImage.extent.size, boundingSize: boundingSize)
    }
        
    let format: UIGraphicsImageRendererFormat
    if #available(iOS 11.0, *) {
      format = UIGraphicsImageRendererFormat.preferred()
    } else {
      format = UIGraphicsImageRendererFormat.default()
    }
    format.scale = 1
    format.opaque = true
    if #available(iOS 12.0, *) {
      format.preferredRange = .extended
    } else {
      format.prefersExtendedRange = true
    }
    
    let image = autoreleasepool { () -> UIImage in
      
      UIGraphicsImageRenderer.init(size: canvasSize, format: format)
        .image { c in
          
          let cgContext = UIGraphicsGetCurrentContext()!
          
          let cgImage = cicontext.createCGImage(croppedImage, from: croppedImage.extent, format: .RGBA8, colorSpace: croppedImage.colorSpace ?? CGColorSpaceCreateDeviceRGB())!
          
          cgContext.saveGState()
          cgContext.translateBy(x: 0, y: canvasSize.height)
          cgContext.scaleBy(x: 1, y: -1)
          cgContext.draw(cgImage, in: CGRect(origin: .zero, size: canvasSize))
          cgContext.restoreGState()

          self.edit.drawer.forEach { drawer in
            drawer.draw(in: cgContext, canvasSize: canvasSize)
          }
          
      }
      
    }
    
    return image
  }
}

