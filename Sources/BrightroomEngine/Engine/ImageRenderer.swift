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
  public let orientation: CGImagePropertyOrientation

  public var edit: Edit

  public init(source: ImageSource, orientation: CGImagePropertyOrientation) {
    self.source = source
    self.orientation = orientation
    edit = .init()
  }

  public func render(resolution: Resolution = .full, completion: @escaping (UIImage) -> Void) {
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
    
    /**
     FIXME: Super-Slow

     TODO: Restores image-orientation

     FIXME: support wide-color. Editing CIImage displayed with wide-color. but rendered image is not wide-color.
     For example, when the image is brighter, the result contains clipping.

     FIMXE: To create DisplayP3, using `UIGraphicsImageRenderer.pngData`. I don't know why `.image` returns a CGImage that is not DisplayP3 against specified color-space. So this is slow.
     */

    let sourceCIImage: CIImage = source.makeCIImage().oriented(orientation)

    assert(
      {
        guard let crop = edit.croppingRect else { return true }
        return crop.imageSize == CGSize(image: sourceCIImage)
      }())

    let crop = edit.croppingRect ?? .init(imageSize: source.readImageSize())

    EngineLog.debug("Source.colorSpace :", sourceCIImage.colorSpace as Any)

    let effectedCIImage = edit.modifiers.reduce(sourceCIImage) { image, modifier in
      modifier.apply(to: image, sourceImage: sourceCIImage)
    }

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
        format.preferredRange = .automatic
      } else {
        format.prefersExtendedRange = true
      }
    }

    let image = autoreleasepool { () -> UIImage in

      EngineLog.debug("[Renderer] Creates a full size image")

      /**
       Creates a full size image
       */
      let fullSizeImage = autoreleasepool { () -> CGImage in

        let targetSize = effectedCIImage.extent.size

        let cgImage = UIGraphicsImageRenderer.init(size: targetSize, format: format)
          ._custom { c in

            let cgContext = c.cgContext
            let ciContext = CIContext(
              cgContext: cgContext,
              options: [
                .workingFormat: CIFormat.RGBAh,
                .highQualityDownsample: true,
                .useSoftwareRenderer: true,
                .cacheIntermediates: false,
                .outputColorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
//                .outputColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
//                .outputColorSpace: CGColorSpace(name: CGColorSpace.extendedSRGB)!
              ]
            )

            #if false
            cgContext.detached {
              let cgImage = ciContext.createCGImage(
                effectedCIImage,
                from: effectedCIImage.extent,
                format: .RGBAh,
                colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
                deferred: true
              )!

              cgContext.draw(cgImage, in: CGRect(origin: .zero, size: targetSize))
            }
            #else
            cgContext.detached {
              ciContext.draw(
                effectedCIImage,
                in: CGRect(origin: .zero, size: targetSize),
                from: effectedCIImage.extent
              )
            }
            #endif

            /**
             Render drawings
             */

            cgContext.detached {
              cgContext.translateBy(x: 0, y: targetSize.height)
              cgContext.scaleBy(x: 1, y: -1)
              self.edit.drawer.forEach { drawer in
                drawer.draw(in: cgContext, canvasSize: effectedCIImage.extent.size)
              }
            }
          }

        return cgImage
      }

      /**
       Creates a cropped image from the full size image.
       */
      let croppedImage = autoreleasepool { () -> CGImage in

        EngineLog.debug("[Renderer] Make cropped image \(crop)")

        let targetRect = crop.cropExtent
        let targetSize = crop.cropExtent.size

        let cgImage = UIGraphicsImageRenderer.init(size: targetSize, format: format)
          ._custom { c in
            let cgContext = c.cgContext

            cgContext.detached {
              cgContext.translateBy(x: -targetRect.minX, y: -targetRect.minY)
              cgContext.draw(fullSizeImage, in: .init(origin: .zero, size: fullSizeImage.size))
            }
          }

        return cgImage
      }

      /**
       Rotates the cropped image.
       */
      let rotatedImage = autoreleasepool { () -> CGImage in

        EngineLog.debug("[Renderer] Rotates the cropped image.")

        let resultSize: CGSize = crop.cropExtent.integral
          .applying(crop.rotation.transform)
          .size

        let cgImage = UIGraphicsImageRenderer.init(size: resultSize, format: format)
          ._custom { c in
            /**
             Step: 3
             */

            do {
              c.cgContext.translateBy(x: resultSize.width / 2, y: resultSize.height / 2)
              c.cgContext.rotate(by: -crop.rotation.angle)
              c.cgContext.translateBy(
                x: -crop.cropExtent.size.width / 2,
                y: -crop.cropExtent.size.height / 2
              )
              c.cgContext.draw(croppedImage, in: .init(origin: .zero, size: crop.cropExtent.size))
            }
          }

        return cgImage
      }

      /**
       Normalizes image coordinate and resizes to the target size.
       */
      let finalizedImage = autoreleasepool { () -> CGImage in

        EngineLog.debug("[Renderer] Normalizes image coordinate and resizes to the target size..")

        let targetSize: CGSize = {
          switch resolution {
          case .full:
            return rotatedImage.size
          case let .resize(maxPixelSize):
            return Geometry.sizeThatAspectFit(size: rotatedImage.size, maxPixelSize: maxPixelSize)
          }
        }()

        let cgImage = UIGraphicsImageRenderer.init(size: targetSize, format: format)
          ._custom { c in
            c.cgContext.draw(rotatedImage, in: .init(origin: .zero, size: targetSize))
          }
        
        return cgImage
      }

      EngineLog.debug("[Renderer] a rendering was successful. Image => \(finalizedImage)")

      return UIImage(cgImage: finalizedImage)
    }

    return image
  }
  
  public func _render(resolution: Resolution = .full) -> UIImage {
    
    let sourceCIImage: CIImage = source.makeCIImage().oriented(orientation)
    
    assert(
      {
        guard let crop = edit.croppingRect else { return true }
        return crop.imageSize == CGSize(image: sourceCIImage)
      }())
    
    let crop = edit.croppingRect ?? .init(imageSize: source.readImageSize())
    
    let ciContext = CIContext(
      options: [
        .workingFormat: CIFormat.RGBAh,
        .highQualityDownsample: true,
        .useSoftwareRenderer: true,
        .cacheIntermediates: false,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
        //                .outputColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        //                .outputColorSpace: CGColorSpace(name: CGColorSpace.extendedSRGB)!
      ]
    )
    
    
    
  }
}

extension UIGraphicsImageRenderer {
  func _custom(_ perform: (UIGraphicsImageRendererContext) -> Void) -> CGImage {
    let d = pngData(actions: perform)
    return UIImage(data: d)!.cgImage!
  }
}

extension CGContext {
  fileprivate func detached(_ perform: () -> Void) {
    saveGState()
    perform()
    restoreGState()
  }
}

extension CGImage {
  fileprivate var size: CGSize {
    return .init(width: width, height: height)
  }
}
