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

import AVFoundation
import CoreImage
import MobileCoreServices
import UIKit

enum ImageTool {
  static func makeImageMetadata(from imageSource: CGImageSource) -> ImageProvider.State.ImageMetadata? {
    let propertiesOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, propertiesOptions) as? [CFString: Any] else {
      return nil
    }

    EngineLog.debug("\(properties)")

    guard
      let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
      let height = properties[kCGImagePropertyPixelHeight] as? CGFloat
    else {
      return nil
    }

    let orientation: CGImagePropertyOrientation = (properties[kCGImagePropertyTIFFOrientation] as? UInt32).flatMap {
      CGImagePropertyOrientation(rawValue: $0)
    } ?? .up

    let size = CGSize(width: width, height: height)

    return .init(orientation: orientation, imageSize: size.applying(cgOrientation: orientation))
  }

  /**
   Returns a pixel size of image.

   https://oleb.net/blog/2011/09/accessing-image-properties-without-loading-the-image-into-memory/
   */
  static func readImageSize(from imageSource: CGImageSource) -> CGSize? {
    let propertiesOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, propertiesOptions) as? [CFString: Any] else {
      return nil
    }

    guard
      let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
      let height = properties[kCGImagePropertyPixelHeight] as? CGFloat
    else {
      return nil
    }
    return CGSize(width: width, height: height)
  }

  static func readOrientation(from imageSource: CGImageSource) -> CGImagePropertyOrientation? {
    let propertiesOptions = [kCGImageSourceShouldCache: false] as CFDictionary

    guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, propertiesOptions) as? [CFString: Any] else {
      return nil
    }

    guard
      let orientation = properties[kCGImagePropertyTIFFOrientation] as? CGImagePropertyOrientation
    else {
      return nil
    }

    return orientation
  }

  static func loadOriginalCGImage(from imageSource: CGImageSource) -> CGImage? {
    CGImageSourceCreateImageAtIndex(imageSource, 0, [:] as CFDictionary)
  }

  static func loadThumbnailCGImage(from imageSource: CGImageSource, maxPixelSize: CGFloat) -> CGImage? {
    let scaledImage = CGImageSourceCreateThumbnailAtIndex(
      imageSource, 0, [
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: false,
      ] as CFDictionary
    )

//    #if DEBUG
//    let size = readImageSize(from: imageProvider)!
//    let scaled = size.scaled(maxPixelSize: maxPixelSize)
//    assert(CGSize(width: scaledImage!.width, height: scaledImage!.height) == scaled)
//    #endif
//
    return scaledImage
  }

  static func writeImageToTmpDirectory(image: UIImage) -> URL? {
    let directory = NSTemporaryDirectory()
    let fileName = UUID().uuidString
    let path = directory + "/" + fileName
    let destination = URL(fileURLWithPath: path)

    guard let data = image.pngData() else {
      return nil
    }

    do {
      try data.write(to: destination, options: [])
    } catch {
      return nil
    }

    return destination
  }

  static func makeNewResizedCIImage(to pixelSize: CGSize, from sourceImage: CIImage) -> CIImage? {
    var targetSize = pixelSize
    targetSize.height.round(.down)
    targetSize.width.round(.down)

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
              let context = CIContext(
                cgContext: c.cgContext,
                options: [.useSoftwareRenderer: sourceImage.cgImage != nil]
              )
              context.draw(sourceImage, in: rect, from: sourceImage.extent)
            }
          }

        let resizedImage = CIImage(image: uiImage)!
          .insertingIntermediate(cache: true)

        return resizedImage
      }
  }

  static func makeResizedCGImage(maxPixelSize: CGFloat, from sourceImage: CGImage) -> CGImage? {
    let imageSize = CGSize(
      width: sourceImage.width,
      height: sourceImage.height
    )

    let targetSize = imageSize.scaled(maxPixelSize: maxPixelSize)

    let format: UIGraphicsImageRendererFormat
    format = UIGraphicsImageRendererFormat.preferred()
    format.scale = 1
    format.opaque = true
    if #available(iOS 12.0, *) {
      format.preferredRange = .automatic
    } else {
      format.prefersExtendedRange = false
    }

    let cgImage = UIGraphicsImageRenderer(size: targetSize, format: format)
      .image { c in
        c.cgContext.translateBy(x: 0, y: targetSize.height)
        c.cgContext.scaleBy(x: 1, y: -1)
        c.cgContext.draw(sourceImage, in: .init(origin: .zero, size: targetSize))
      }
      .cgImage

    return cgImage
  }

  static func makeImageForJPEGOptimizedSharing(image: CGImage, quality: CGFloat = 1) -> Data {
    let data = NSMutableData()

    let destination = CGImageDestinationCreateWithData(
      data,
      kUTTypeJPEG,
      1,
      [:] as CFDictionary
    )!

    CGImageDestinationAddImage(
      destination,
      image,
      [
        kCGImageDestinationLossyCompressionQuality : quality,
        kCGImageDestinationOptimizeColorForSharing: true,
      ] as CFDictionary)

    CGImageDestinationFinalize(destination)

    return data as Data
  }
  
  static func makeImageForPNGOptimizedSharing(image: CGImage) -> Data {
    let data = NSMutableData()
    
    let destination = CGImageDestinationCreateWithData(
      data,
      kUTTypePNG,
      1,
      [:] as CFDictionary
    )!
    
    CGImageDestinationAddImage(
      destination,
      image,
      [
        kCGImageDestinationOptimizeColorForSharing: true,
      ] as CFDictionary)
    
    CGImageDestinationFinalize(destination)
    
    return data as Data
  }
}
