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
import SwiftUI
import UIKit

public final class ImageRenderer {

  public struct Options {

    public var resolution: Resolution = .full
    public var workingFormat: CIFormat = .ARGB8
    public var workingColorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    public init(resolution: ImageRenderer.Resolution = .full, workingFormat: CIFormat = .ARGB8) {
      self.resolution = resolution
      self.workingFormat = workingFormat
    }

  }

  /**
   A result of rendering.
   */
  public struct Rendered {

    public enum DataType {
      case jpeg(quality: CGFloat)
      case png
    }

    /// A rendered image that working on DisplayP3
    public let cgImageDisplayP3: CGImage

    public var uiImageDisplayP3: UIImage {
      .init(cgImage: cgImageDisplayP3)
    }

    @available(iOS 13.0, *)
    public var swiftUIImageDisplayP3: SwiftUI.Image {
      .init(decorative: cgImageDisplayP3, scale: 1, orientation: .up)
    }

    init(cgImageDisplayP3: CGImage) {
      assert(cgImageDisplayP3.colorSpace == CGColorSpace.init(name: CGColorSpace.displayP3))
      self.cgImageDisplayP3 = cgImageDisplayP3
    }

    /**
     Makes a data of the image that optimized for sharing.

     Since the rendered image is working on DisplayP3 profile, that data might display wrong color on other platform devices.
     To avoid those issues, use this method to create data to send instead of creating data from `cgImageDisplayP3`.
     */
    public func makeOptimizedForSharingData(dataType: DataType) -> Data {
      switch dataType {
      case .jpeg(let quality):
        return ImageTool.makeImageForJPEGOptimizedSharing(image: cgImageDisplayP3, quality: quality)
      case .png:
        return ImageTool.makeImageForPNGOptimizedSharing(image: cgImageDisplayP3)
      }
    }

  }

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

  public func render(
    options: Options = .init(),
    completion: @escaping (
      Result<Rendered, Error>
    ) -> Void
  ) {
    type(of: self).queue.async {
      do {
        let rendered = try self.render()
        DispatchQueue.main.async {
          completion(.success(rendered))
        }
      } catch {
        DispatchQueue.main.async {
          completion(.failure(error))
        }
      }
    }
  }

  /**
   Renders an image according to the editing.

   - Attension: This operation can be run background-thread.
   */
  public func render(options: Options = .init()) throws -> Rendered {
    if edit.drawer.isEmpty, edit.modifiers.isEmpty {
      return try renderOnlyCropping(options: options)
    } else {
      return try renderRevison2(options: options)
    }
  }

  /**
   Render for only cropping using CoreGraphics
   */
  private func renderOnlyCropping(options: Options = .init()) throws -> Rendered {

    EngineLog.debug(.renderer, "Start render in using CoreGraphics")

    /*
     ===
     ===
     ===
     */
    EngineLog.debug(.renderer, "Load full resolution CGImage from ImageSource.")

    let sourceCGImage: CGImage = source.loadOriginalCGImage()

    /*
     ===
     ===
     ===
     */
    EngineLog.debug(.renderer, "Fix orientation")

    let orientedImage = try sourceCGImage.oriented(orientation)
    
    /*
     ===
     ===
     ===
     */
    let crop = edit.croppingRect ?? .init(imageSize: source.readImageSize())
    EngineLog.debug(.renderer, "Crop CGImage with extent \(crop)")

    let croppedImage = try orientedImage.cropping(to: crop.cropExtent).unwrap(
      orThrow: "Failed to crop"
    )

    /*
     ===
     ===
     ===
     */
    EngineLog.debug(.renderer, "Resize if needed")


    let resizedImage: CGImage

    switch options.resolution {
    case .full:
      resizedImage = croppedImage
    case .resize(let maxPixelSize):
      resizedImage = try croppedImage.resized(maxPixelSize: maxPixelSize)
    }

    /*
     ===
     ===
     ===
     */
    EngineLog.debug(.renderer, "Rotation")

    let rotatedImage = try resizedImage.makeRotatedIfNeeded(rotation: crop.rotation)

    return .init(cgImageDisplayP3: rotatedImage)
  }

  /**
   Render for full features using CoreImage and CoreGraphics
   */
  private func renderRevison2(
    options: Options = .init(),
    debug: @escaping (CIImage) -> Void = { _ in }
  ) throws -> Rendered {

    let ciContext = CIContext(
      options: [
        .workingFormat: options.workingFormat,
        .highQualityDownsample: true,
        .useSoftwareRenderer: false,
        .cacheIntermediates: false,
      ]
    )

    let startTime = CACurrentMediaTime()

    EngineLog.debug(.renderer, "Start render in v2 using CIContext => \(ciContext)")

    /*
     ===
     ===
     ===
     */
    EngineLog.debug(.renderer, "Take full resolution CIImage from ImageSource.")

    let sourceCIImage: CIImage = source.makeOriginalCIImage().oriented(orientation)

    EngineLog.debug(.renderer, "Input oriented CIImage => \(sourceCIImage)")

    assert(
      {
        guard let crop = edit.croppingRect else { return true }
        return crop.imageSize == CGSize(image: sourceCIImage)
      }()
    )

    /*
     ===
     ===
     ===
     */
    EngineLog.debug(.renderer, "Applies Effect")

    let effected_CIImage = edit.modifiers.reduce(sourceCIImage) { image, modifier in
      modifier.apply(to: image, sourceImage: sourceCIImage)
    }

    /*
     ===
     ===
     ===
     */
    EngineLog.debug(.renderer, "Applies Crop to effected image")

    let crop = edit.croppingRect ?? .init(imageSize: source.readImageSize())

    let cropped_effected_CIImage = effected_CIImage.cropped(to: crop)

    debug(cropped_effected_CIImage)

    /*
     ===
     ===
     ===
     */
    EngineLog.debug(.renderer, "Creates CGImage from crop applied CIImage.")

    /**
     To keep wide-color(DisplayP3), use createCGImage instead drawing with CIContext
     */
    let cropped_effected_CGImage = ciContext.createCGImage(
      cropped_effected_CIImage,
      from: cropped_effected_CIImage.extent,
      format: options.workingFormat,
      colorSpace: options.workingColorSpace,
      deferred: false
    )!

    EngineLog.debug(.renderer, "Created effected CGImage => \(cropped_effected_CGImage)")

    /*
     ===
     ===
     ===
     */

    let drawings_CGImage: CGImage

    if edit.drawer.isEmpty {
      EngineLog.debug(.renderer, "No drawings")

      drawings_CGImage = cropped_effected_CGImage
    } else {
      EngineLog.debug(.renderer, "Found drawings")
      /**
       Render drawings
       */
      drawings_CGImage = try CGContext.makeContext(for: cropped_effected_CGImage)
        .perform { c in

          c.draw(
            cropped_effected_CGImage,
            in: .init(origin: .zero, size: cropped_effected_CGImage.size)
          )
          c.translateBy(x: -crop.cropExtent.origin.x, y: -crop.cropExtent.origin.y)

          self.edit.drawer.forEach { drawer in
            drawer.draw(in: c)
          }
        }
        .makeImage()
        .unwrap()
    }

    /*
     ===
     ===
     ===
     */

    let resizedImage: CGImage

    switch options.resolution {
    case .full:

      EngineLog.debug(.renderer, "No resizing")

      resizedImage = drawings_CGImage

    case let .resize(maxPixelSize):

      EngineLog.debug(.renderer, "Resizing with maxPixelSize: \(maxPixelSize)")

      resizedImage = try drawings_CGImage.resized(maxPixelSize: maxPixelSize)

    }

    /*
     ===
     ===
     ===
     */

    EngineLog.debug(.renderer, "Rotates image if needed")

    let rotatedImage = try resizedImage.makeRotatedIfNeeded(rotation: crop.rotation)

    let duration = CACurrentMediaTime() - startTime
    EngineLog.debug(.renderer, "Rendering has completed - took \(duration * 1000)ms")

    return .init(cgImageDisplayP3: rotatedImage)

  }
}

extension CGContext {
  @discardableResult
  func perform(_ drawing: (CGContext) -> Void) -> CGContext {
    UIGraphicsPushContext(self)
    defer {
      UIGraphicsPopContext()
    }
    drawing(self)
    return self
  }

  static func makeContext(for image: CGImage, size: CGSize? = nil) throws -> CGContext {
    let context = CGContext.init(
      data: nil,
      width: size.map { Int($0.width) } ?? image.width,
      height: size.map { Int($0.height) } ?? image.height,
      bitsPerComponent: image.bitsPerComponent,
      bytesPerRow: 0,
      space: try image.colorSpace.unwrap(),
      bitmapInfo: image.bitmapInfo.rawValue
    )

    return try context.unwrap()
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

  fileprivate func makeRotatedIfNeeded(rotation: EditingCrop.Rotation) throws -> CGImage {
    guard rotation != .angle_0 else {
      return self
    }

    var rotatedSize: CGSize =
      size
      .applying(rotation.transform)

    rotatedSize.width = abs(rotatedSize.width)
    rotatedSize.height = abs(rotatedSize.height)

    let rotatingContext = try CGContext.makeContext(for: self, size: rotatedSize)
      .perform { c in
        c.translateBy(x: rotatedSize.width / 2, y: rotatedSize.height / 2)
        c.rotate(by: -rotation.angle)
        c.translateBy(
          x: -size.width / 2,
          y: -size.height / 2
        )
        c.draw(self, in: .init(origin: .zero, size: self.size))
      }

    return try rotatingContext.makeImage().unwrap()
  }
}

extension Optional {
  internal func unwrap(
    orThrow debugDescription: String? = nil,
    file: StaticString = #file,
    function: StaticString = #function,
    line: UInt = #line
  ) throws -> Wrapped {
    if let value = self {
      return value
    }
    throw Optional.BrightroomUnwrappedNilError(
      debugDescription,
      file: file,
      function: function,
      line: line
    )
  }

  public struct BrightroomUnwrappedNilError: Swift.Error, CustomDebugStringConvertible {
    let file: StaticString
    let function: StaticString
    let line: UInt

    // MARK: Public

    public init(
      _ debugDescription: String? = nil,
      file: StaticString = #file,
      function: StaticString = #function,
      line: UInt = #line
    ) {
      self.debugDescription = debugDescription ?? "Failed to unwrap on \(file):\(function):\(line)"
      self.file = file
      self.function = function
      self.line = line
    }

    // MARK: CustomDebugStringConvertible

    public let debugDescription: String
  }
}

extension CGImage {

  func resized(maxPixelSize: CGFloat) throws -> CGImage {

    let cgImage = try autoreleasepool { () -> CGImage? in

      let targetSize = Geometry.sizeThatAspectFit(
        size: size,
        maxPixelSize: maxPixelSize
      )

      let context = try CGContext.makeContext(for: self, size: targetSize)
        .perform { c in
          c.interpolationQuality = .high
          c.draw(self, in: c.boundingBoxOfClipPath)
        }
      return context.makeImage()
    }

    return try cgImage.unwrap()
  }

  func oriented(_ orientation: CGImagePropertyOrientation) throws -> CGImage {

    guard orientation != .up else {
      return self
    }

    let size = self.size

    var transform: CGAffineTransform = .identity

    switch orientation {
    case .down, .downMirrored:
      transform = transform.translatedBy(x: size.width, y: size.height)
      transform = transform.rotated(by: CGFloat.pi)
    case .left, .leftMirrored:
      transform = transform.translatedBy(x: size.width, y: 0)
      transform = transform.rotated(by: CGFloat.pi / 2.0)
    case .right, .rightMirrored:
      transform = transform.translatedBy(x: 0, y: size.height)
      transform = transform.rotated(by: CGFloat.pi / -2.0)
    case .up, .upMirrored:
      break
    }

    // Flip image one more time if needed to, this is to prevent flipped image
    switch orientation {
    case .upMirrored, .downMirrored:
      transform = transform.translatedBy(x: size.width, y: 0)
      transform = transform.scaledBy(x: -1, y: 1)
    case .leftMirrored, .rightMirrored:
      transform = transform.translatedBy(x: size.height, y: 0)
      transform = transform.scaledBy(x: -1, y: 1)
    case .up, .down, .left, .right:
      break
    }

    let orientedCGImage = try autoreleasepool { () -> CGImage? in
      try CGContext.makeContext(for: self)
        .perform { (c) in
          c.concatenate(transform)

          var drawRect: CGRect = .zero
          switch orientation {
          case .left, .leftMirrored, .right, .rightMirrored:
            drawRect.size = CGSize(width: size.height, height: size.width)
          default:
            drawRect.size = CGSize(width: size.width, height: size.height)
          }

          c.draw(self, in: drawRect)
        }
        .makeImage()
    }

    return try orientedCGImage.unwrap()
  }
}
