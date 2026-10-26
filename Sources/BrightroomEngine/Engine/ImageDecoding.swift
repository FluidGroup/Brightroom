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

import CoreGraphics
import Foundation
import ImageIO

/// Reads image metadata and decodes or downsamples bitmaps for
/// `SourceImage` and the editing preview.
enum ImageDecoding {

  /// The orientation and oriented pixel size read from image properties.
  struct ImageMetadata: Equatable {
    var orientation: CGImagePropertyOrientation
    /// The pixel size with the orientation applied.
    var pixelSize: CGSize
  }

  static func makeImageMetadata(
    from imageSource: CGImageSource
  ) -> ImageMetadata? {
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

    return .init(orientation: orientation, pixelSize: size.applying(cgOrientation: orientation))
  }

  static func makeDecodedCGImage(from image: CGImage) -> CGImage? {
    autoreleasepool {
      guard let context = try? CGContext.makeContext(for: image) else {
        return nil
      }

      context.interpolationQuality = .none
      context.draw(image, in: context.boundingBoxOfClipPath)
      return context.makeImage()
    }
  }

  /// Downsamples the image so that its **shortest** side is at most
  /// `shortSideLength` pixels.
  ///
  /// This is a short-side target, not a longest-side cap (which is what
  /// `maxPixelSize` means). The longest side lands at
  /// `shortSideLength × aspectRatio` and may far exceed it — a 4032×3024
  /// source with a length of 2560 loads at 3413×2560 — and an image whose
  /// shortest side is already below it is not downsampled at all, so a
  /// 6000×2000 panorama loads at full resolution.
  ///
  /// - Note: Whether this should instead be a true longest-side cap (bounding
  ///   the memory of extreme aspect ratios at the cost of preview detail on
  ///   ordinary photos) is an open product decision. The behavior is documented
  ///   here as it stands; changing it moves preview detail everywhere
  ///   downstream.
  static func makeResizedCGImage(
    from imageSource: CGImageSource,
    shortSideLength: CGFloat
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
      guard smallestSide >= shortSideLength else {
        return largestSide
      }
      return largestSide * shortSideLength / smallestSide
    }()
    return makeResizedCGImage(from: imageSource, maxPixelSize: maxPixelSize)
  }

  static func makeResizedCGImage(
    from imageSource: CGImageSource,
    maxPixelSize: CGFloat
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

  /// Downsamples the image so that its **shortest** side is at most
  /// `shortSideLength` pixels.
  ///
  /// Short-side target, not a longest-side cap; see
  /// ``makeResizedCGImage(from:shortSideLength:)`` for the
  /// full contract and its consequences for wide aspect ratios.
  static func makeResizedCGImage(
    from sourceImage: CGImage,
    shortSideLength: CGFloat
  ) -> CGImage? {
    let maxPixelSize: CGFloat = {
      let largestSide = max(sourceImage.size.width, sourceImage.size.height)
      let smallestSide = min(sourceImage.size.width, sourceImage.size.height)
      guard smallestSide >= shortSideLength else {
        return largestSide
      }
      return largestSide * shortSideLength / smallestSide
    }()
    return makeResizedCGImage(from: sourceImage, maxPixelSize: maxPixelSize)
  }
  
  static func makeResizedCGImage(
    from sourceImage: CGImage,
    maxPixelSize: CGFloat
  ) -> CGImage? {

    let imageSize = CGSize(
      width: sourceImage.width,
      height: sourceImage.height
    )

    let targetSize: CGSize = imageSize.scaled(maxPixelSize: maxPixelSize)

    guard let context = try? CGContext.makeContext(for: sourceImage, size: targetSize) else {
      return nil
    }
    return context.perform({ c in
      c.draw(sourceImage, in: .init(origin: .zero, size: targetSize))
    }).makeImage()
  }
}
