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
    case resize(maxPixelSize: CGFloat)
  }
  
  public struct Edit {
    public var croppingRect: EditingCrop?
    public var modifiers: [Filtering] = []
    public var drawer: [GraphicsDrawing] = []
  }
  
  public let source: ImageSource
  
  public var edit: Edit
  
  public init(source: ImageSource) {
    self.source = source
    edit = .init()
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
    let sourceCIImage: CIImage = source.makeCIImage()
    
    assert(
      {
        guard let crop = edit.croppingRect else { return true }
        return crop.imageSize == CGSize(image: sourceCIImage)
      }())
    
    let crop = edit.croppingRect ?? .init(imageSize: source.readImageSize())
    
    /*
    let croppedImage: CIImage = {
      let sourceImage: CIImage
      
      if let crop = edit.croppingRect {
        /**
         The reason why here does transformed in pre and post:
         Core Image's coordinate system mismatches with UIKIt.
         Zero-point is bottom-left and UIKit's zero-point is top-left.
         To solve this mismatch while cropping, flips and crops and finally flips.
         */
        
        sourceImage = sourceCIImage
          /* pre */
          .transformed(by: .init(scaleX: 1, y: -1))
          .transformed(by: .init(translationX: 0, y: sourceCIImage.extent.height))
          
          /* apply */
          .cropped(to: crop.cropExtent.integral)
          .transformed(by: crop.rotation.transform)
          
          /* post */
          .transformed(by: .init(scaleX: 1, y: -1))
          .transformed(by: .init(translationX: 0, y: sourceCIImage.extent.height))
      } else {
        sourceImage = sourceCIImage
      }
      
      let result = edit.modifiers.reduce(sourceImage) { image, modifier in
        modifier.apply(to: image, sourceImage: sourceImage)
      }
      
      return result
      
    }()
    */
    
    EngineLog.debug("Source.colorSpace :", sourceCIImage.colorSpace as Any)
    
    let effectedCIImage = edit.modifiers.reduce(sourceCIImage) { image, modifier in
      modifier.apply(to: image, sourceImage: sourceCIImage)
    }
    
    let imagePixelSize: CGSize = effectedCIImage.extent.size
          
    let format: UIGraphicsImageRendererFormat
    do {
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
    }
    
    let resultImage = autoreleasepool { () -> UIImage in
      
      let resultSize: CGSize = crop.cropExtent.integral
        .applying(crop.rotation.transform)
        .size
            
      return UIGraphicsImageRenderer.init(size: resultSize, format: format)
        .image { c in
          
          /**
           Step: 1
           */
          let fullImageIayer = CGLayer(c.cgContext, size: imagePixelSize, auxiliaryInfo: nil)!
          renderFullImage: do {
            /**
             Render image
             */
            
            let cgContext = fullImageIayer.context!
            let ciContext = CIContext(cgContext: cgContext, options: [.workingColorSpace : effectedCIImage.colorSpace as Any])
            
            cgContext.detached {
              cgContext.translateBy(x: 0, y: imagePixelSize.height)
              cgContext.scaleBy(x: 1, y: -1)
              ciContext.draw(
                effectedCIImage,
                in: CGRect(origin: .zero, size: imagePixelSize),
                from: effectedCIImage.extent
              )
            }
            
            /**
             Render drawings
             */
            
            self.edit.drawer.forEach { drawer in
              drawer.draw(in: cgContext, canvasSize: imagePixelSize)
            }
          }
          
          /**
           Step: 2
           */
          
          let croppedImageLayer = CGLayer(c.cgContext, size: crop.cropExtent.size, auxiliaryInfo: nil)!
          
          renderCropped: do {
            
            let cgContext = croppedImageLayer.context!
            
            cgContext.translateBy(x: -crop.cropExtent.minX, y: -crop.cropExtent.minY)
            cgContext.draw(fullImageIayer, at: .zero)
                      
          }
          
          /**
           Step: 3
           */
                              
          do {
            let layerSize = croppedImageLayer.size
            c.cgContext.translateBy(x: resultSize.width / 2, y: resultSize.height / 2)
            c.cgContext.rotate(by: crop.rotation.angle)
            c.cgContext.translateBy(x: -layerSize.width / 2, y: -layerSize.height / 2)
            c.cgContext.draw(croppedImageLayer, at: .zero)
          }
         
        }
    }
    
    EngineLog.debug("[Renderer] a rendering was successful. Image => \(resultImage)")
    
    return resultImage
  }
}

extension CGContext {
  fileprivate func detached(_ perform: () -> Void) {
    saveGState()
    perform()
    restoreGState()
  }
}
