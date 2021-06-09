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

/// A set of functions that handle image and manipulations.
public enum ImageTool {
  public enum Error: Swift.Error {
    case imageHasNoColorspace
    case imageIsNotCGImageBacked
    case unsupporedPixelFormat(model: CGColorSpaceModel, bitPerComponent: Int, bitPerPixel: Int, alphaInfo: CGImageAlphaInfo, containsFloatComponents: Bool)
  }

  /// Checks that the pixel format is supported by core graphics.
  /// Throws in case an error is found.
  public static func validatePixelFormat(_ image: UIImage) throws {
    guard let cgImage = image.cgImage else {
      throw Error.imageIsNotCGImageBacked
    }
    guard let colorSpace = cgImage.colorSpace else {
      throw Error.imageHasNoColorspace
    }
    let isPixelFromatSupported: Bool =
      {
        #if os(iOS) || os(watchOS) || os(tvOS)
        let iOS = true
        #else
        let iOS = false
        #endif
        #if os(OSX)
        let macOS = true
        #else
        let macOS = false
        #endif
        switch (colorSpace.model, cgImage.bitsPerPixel, cgImage.bitsPerComponent, cgImage.alphaInfo, cgImage.bitmapInfo.contains(.floatComponents)) {
        case (.unknown, 8, 8, .alphaOnly, false):
          return macOS || iOS
        case (.monochrome, 8, 8, .none, false):
          return macOS || iOS
        case (.monochrome, 8, 8, .alphaOnly, false):
          return macOS || iOS
        case (.monochrome, 16, 16, .none, false):
          return macOS
        case (.monochrome, 32, 32, .none, true):
          return macOS
        case (.rgb, 16, 5, .noneSkipFirst, false):
          return macOS || iOS
        case (.rgb, 32, 8, .noneSkipFirst, false):
          return macOS || iOS
        case (.rgb, 32, 8, .noneSkipLast, false):
          return macOS || iOS
        case (.rgb, 32, 8, .premultipliedFirst, false):
          return macOS || iOS
        case (.rgb, 32, 8, .premultipliedLast, false):
          return macOS || iOS
        case (.rgb, 64, 16, .premultipliedLast, false):
          return macOS
        case (.rgb, 64, 16, .noneSkipLast, false):
          return macOS
        case (.rgb, 128, 32, .noneSkipLast, true):
          return macOS
        case (.rgb, 128, 32, .premultipliedLast, true):
          return macOS
        case (.cmyk, 32, 8, .none, false):
          return macOS
        case (.cmyk, 64, 16, .none, false):
          return macOS
        case (.cmyk, 128, 32, .none, true):
          return macOS
        default:
          return false
        }
      }()
    guard isPixelFromatSupported else {
      throw Error.unsupporedPixelFormat(model: colorSpace.model, bitPerComponent: cgImage.bitsPerComponent, bitPerPixel: cgImage.bitsPerPixel, alphaInfo: cgImage.alphaInfo, containsFloatComponents: cgImage.bitmapInfo.contains(.floatComponents))
    }
    // Success ! 
  }

  public static func makeImageMetadata(
    from imageSource: CGImageSource
  ) -> ImageProvider.State.ImageMetadata? {
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
  public static func readImageSize(from imageSource: CGImageSource) -> CGSize? {
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

  public static func readOrientation(
    from imageSource: CGImageSource
  ) -> CGImagePropertyOrientation? {
    let propertiesOptions = [kCGImageSourceShouldCache: false] as CFDictionary

    guard
      let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, propertiesOptions)
        as? [CFString: Any]
    else {
      return nil
    }

    let _orientation: CGImagePropertyOrientation? =
      (properties[kCGImagePropertyTIFFOrientation] as? UInt32).flatMap {
        CGImagePropertyOrientation(rawValue: $0)
      }

    guard
      let orientation = _orientation
    else {
      return nil
    }

    return orientation
  }

  public static func loadOriginalCGImage(
    from imageSource: CGImageSource,
    fixesOrientation: Bool
  ) -> CGImage? {
    CGImageSourceCreateImageAtIndex(
      imageSource,
      0,
      [
        kCGImageSourceCreateThumbnailWithTransform: fixesOrientation
      ] as CFDictionary
    )
  }

  public static func writeImageToTmpDirectory(image: UIImage) -> URL? {
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

  public static func makeResizedCGImage(
    from imageSource: CGImageSource,
    maxPixelSizeHint: CGFloat,
    fixesOrientation: Bool
    ) -> CGImage? {
    let imageSize: CGSize = {
      guard
        let imageProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [AnyHashable: Any]
      else {
        return .zero
      }
      let pixelWidth = imageProperties[kCGImagePropertyPixelWidth as String] as! CFNumber
      let pixelHeight = imageProperties[kCGImagePropertyPixelHeight as String] as! CFNumber
      var width: CGFloat = 0
      var height: CGFloat = 0
      CFNumberGetValue(pixelWidth, .cgFloatType, &width)
      CFNumberGetValue(pixelHeight, .cgFloatType, &height)
      return CGSize(width: width, height: height)
  }()
    let maxPixelSize: CGFloat = {
      let largestSide = max(imageSize.width, imageSize.height)
      let smallestSide = min(imageSize.width, imageSize.height)
      guard smallestSide >= maxPixelSizeHint else {
        return largestSide
      }
      return largestSide * maxPixelSizeHint / smallestSide
    }()
    return makeResizedCGImage(from: imageSource, maxPixelSize: maxPixelSize, fixesOrientation: fixesOrientation)
  }

  public static func makeResizedCGImage(
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

  public static func makeResizedCGImage(
    from sourceImage: CGImage,
    maxPixelSizeHint: CGFloat
  ) -> CGImage? {
    let maxPixelSize: CGFloat = {
      let largestSide = max(sourceImage.size.width, sourceImage.size.height)
      let smallestSide = min(sourceImage.size.width, sourceImage.size.height)
      guard smallestSide >= maxPixelSizeHint else {
        return largestSide
      }
      return largestSide * maxPixelSizeHint / smallestSide
    }()
    return makeResizedCGImage(from: sourceImage, maxPixelSize: maxPixelSize)
  }
  
  public static func makeResizedCGImage(
    from sourceImage: CGImage,
    maxPixelSize: CGFloat
  ) -> CGImage? {

    let imageSize = CGSize(
      width: sourceImage.width,
      height: sourceImage.height
    )

    let targetSize: CGSize = {
      imageSize.scaled(maxPixelSize: maxPixelSize)
    }()
    do {
      let image = try CGContext.makeContext(for: sourceImage, size: targetSize)
        .perform { c in
          c.draw(sourceImage, in: .init(origin: .zero, size: targetSize))
        }
        .makeImage()
      EngineSanitizer.global.onDidFindRuntimeError(
        .failedToCreateResizedCGImage(sourceImage: sourceImage, maxPixelSize: maxPixelSize)
      )
      return image
    } catch {
      EngineSanitizer.global.onDidFindRuntimeError(
        .failedToCreateCGContext(sourceImage: sourceImage)
      )
      return nil
    }

  }

  /// Makes an image that optimized for sharing.
  /// It contains fixing color space to sRGB
  public static func makeImageForJPEGOptimizedSharing(
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

  /// Makes an image that optimized for sharing.
  /// It contains fixing color space to sRGB
  public static func makeImageForPNGOptimizedSharing(image: CGImage) -> Data {
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
