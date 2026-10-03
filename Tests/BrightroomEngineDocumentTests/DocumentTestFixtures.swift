import CoreGraphics
import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers

@testable import BrightroomEngine
import BrightroomParametric
@testable import BrightroomUI

/// Small images and features shared by the document tests.
enum DocumentTestFixtures {

  /// A bitmap filled with `color`, 40 x 20 by default.
  static func makeCGImage(width: Int = 40, height: Int = 20, color: UIColor = .red) throws -> CGImage {
    let context = try #require(
      CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      )
    )
    context.setFillColor(color.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
  }

  /// A 40 x 20 JPEG whose EXIF orientation turns it sideways (`.right`), so
  /// its oriented size is 20 x 40.
  static func makeRotatedJPEG() throws -> Data {
    let data = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
    )
    CGImageDestinationAddImage(
      destination,
      try makeCGImage(),
      [kCGImagePropertyOrientation: CGImagePropertyOrientation.right.rawValue] as CFDictionary
    )
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
  }

  /// A 40 x 20 mid-gray JPEG with one gray channel, like a black-and-white
  /// scan.
  static func makeGrayscaleJPEG() throws -> Data {
    let context = try #require(
      CGContext(
        data: nil,
        width: 40,
        height: 20,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!,
        bitmapInfo: CGImageAlphaInfo.none.rawValue
      )
    )
    context.setFillColor(gray: 0.5, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
    let data = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
    )
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
  }

  /// The oriented size of `makeRotatedJPEG()`.
  static let rotatedJPEGSize = CGSize(width: 20, height: 40)

  static func makeImage() throws -> SourceImage {
    try SourceImage(data: makeRotatedJPEG())
  }

  /// A full-image `ImageEditorFeature` of `makeImage()` with an exposure.
  static func exposure(_ value: Double) -> ImageEditorFeature {
    var feature = ImageEditorFeature(imageSize: rotatedJPEGSize)
    feature.effects.exposure = ExposureFeature(ev: value)
    return feature
  }

  static func makeDocument(
    feature: ImageEditorFeature = exposure(0),
    history: ImageEditorDocument.History = .init()
  ) throws -> ImageEditorDocument {
    EditingDocument(source: try makeImage(), feature: feature, history: history)
  }
}
