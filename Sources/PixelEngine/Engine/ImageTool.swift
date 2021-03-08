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
import AVFoundation

public enum ImageTool {

  private static let ciContext = CIContext(options: [
    .useSoftwareRenderer : false,
    .highQualityDownsample: true,
    .workingColorSpace : CGColorSpaceCreateDeviceRGB()
    ]
  )

  public static func makeNewResizedCIImage(to pixelSize: CGSize, from sourceImage: CIImage) -> CIImage? {

    var targetSize = pixelSize
    targetSize.height.round(.down)
    targetSize.width.round(.down)

    let scaleX = targetSize.width / sourceImage.extent.width
    let scaleY = targetSize.height / sourceImage.extent.height
    
    /*
    do {
      let resizeFilter = CIFilter(name: "CILanczosScaleTransform")!
      // Desired output size
      
      // Compute scale and corrective aspect ratio
      let scale = pixelSize.height / sourceImage.extent.height
      let aspectRatio = pixelSize.width / sourceImage.extent.width * scale
      
      // Apply resizing
      resizeFilter.setValue(sourceImage, forKey: kCIInputImageKey)
      resizeFilter.setValue(scale, forKey: kCIInputScaleKey)
      resizeFilter.setValue(pixelSize.width / pixelSize.height, forKey: kCIInputAspectRatioKey)
      let outputImage = resizeFilter.outputImage
      
      return outputImage!.insertingIntermediate(cache: true)
    }
     */

    return
      autoreleasepool { () -> CIImage? in

        let format: UIGraphicsImageRendererFormat
        format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = true
        if #available(iOS 12.0, *) {
          format.preferredRange = .automatic
        } else {
          format.prefersExtendedRange = false
        }
        
        let uiImage = UIGraphicsImageRenderer.init(size: targetSize, format: format)
          .image { c in
            
            autoreleasepool {
              EngineLog.debug("[Resizing] Use softwareRenderer => \(sourceImage.cgImage != nil)")
              
              let rect = CGRect(origin: .zero, size: targetSize)
              c.cgContext.translateBy(x: 0, y: targetSize.height)
              c.cgContext.scaleBy(x: 1, y: -1)
              let context = CIContext(cgContext: c.cgContext, options: [.useSoftwareRenderer : sourceImage.cgImage != nil])
              context.draw(sourceImage, in: rect, from: sourceImage.extent)
              
            }
          }
                
        let resizedImage = CIImage(image: uiImage)!
          .insertingIntermediate(cache: true)
      
        return resizedImage
      }
  }

}
