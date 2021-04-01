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
  static func makeImageMetadata(from imageSource: CGImageSource) -> ImageProvider.State
    .ImageMetadata?
  {
    let propertiesOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard
      let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, propertiesOptions)
        as? [CFString: Any]
    else {
      return nil
    }

    EngineLog.debug("\(properties)")

    guard
      let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
      let height = properties[kCGImagePropertyPixelHeight] as? CGFloat
    else {
      return nil
    }

    let orientation: CGImagePropertyOrientation =
      (properties[kCGImagePropertyTIFFOrientation] as? UInt32).flatMap {
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
    guard
      let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, propertiesOptions)
        as? [CFString: Any]
    else {
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

    guard
      let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, propertiesOptions)
        as? [CFString: Any]
    else {
      return nil
    }

    guard
      let orientation = properties[kCGImagePropertyTIFFOrientation] as? CGImagePropertyOrientation
    else {
      return nil
    }

    return orientation
  }

  static func loadOriginalCGImage(from imageSource: CGImageSource, fixesOrientation: Bool)
    -> CGImage?
  {
    CGImageSourceCreateImageAtIndex(
      imageSource,
      0,
      [
        kCGImageSourceCreateThumbnailWithTransform: fixesOrientation
      ] as CFDictionary
    )
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

  static func makeResizedCGImage(
    from imageSource: CGImageSource,
    maxPixelSize: CGFloat,
    fixesOrientation: Bool
  )
    -> CGImage?
  {

    let scaledImage = try? CGImageSourceCreateThumbnailAtIndex(
      imageSource,
      0,
      [
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: false,
      ] as CFDictionary
    )
    .flatMap { image in
      try CGContext.makeContext(for: image).perform { (c) in
        c.draw(image, in: c.boundingBoxOfClipPath)
      }
      .makeImage()
    }

    return scaledImage
  }

  static func makeResizedCGImage(
    from sourceImage: CGImage,
    maxPixelSize: CGFloat
  ) -> CGImage? {

    let imageSize = CGSize(
      width: sourceImage.width,
      height: sourceImage.height
    )

    let targetSize = imageSize.scaled(maxPixelSize: maxPixelSize)

    let image = try? CGContext.makeContext(for: sourceImage, size: targetSize)
      .perform { c in
        c.draw(sourceImage, in: .init(origin: .zero, size: targetSize))
      }
      .makeImage()

    return image
  }

  static func makeImageForJPEGOptimizedSharing(
    image: CGImage,
    quality: CGFloat = 1
  ) -> Data {
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
        kCGImageDestinationLossyCompressionQuality: quality,
        kCGImageDestinationOptimizeColorForSharing: true,
      ] as CFDictionary
    )

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
        kCGImageDestinationOptimizeColorForSharing: true
      ] as CFDictionary
    )

    CGImageDestinationFinalize(destination)

    return data as Data
  }
}
