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
    return try! UIImage(cgImage: renderRevison2(resolution: resolution))

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

  public func renderRevison2(
    resolution: Resolution = .full,
    debug: @escaping (CIImage) -> Void = { _ in }
  ) throws -> CGImage {
    
    let ciContext = CIContext(
      options: [
        .workingFormat: CIFormat.RGBAh,
        .highQualityDownsample: true,
        //        .useSoftwareRenderer: true,
        .cacheIntermediates: false,
      ]
    )

    EngineLog.debug(.renderer, "Start render in v2 using CIContext => \(ciContext)")

    /*
     ===
     ===
     ===
     */
    EngineLog.debug(.renderer, "Take full resolution CIImage from ImageSource.")

    let sourceCIImage: CIImage = source.makeCIImage().oriented(orientation)

    EngineLog.debug(.renderer, "Input oriented CIImage => \(sourceCIImage)")

    assert(
      {
        guard let crop = edit.croppingRect else { return true }
        return crop.imageSize == CGSize(image: sourceCIImage)
      }())

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
      format: .RGBAh,
      colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
      deferred: true
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
            drawer.draw(in: c, canvasSize: CGSize(width: c.width, height: c.height))
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

    switch resolution {
    case .full:
      
      EngineLog.debug(.renderer, "No resizing")

      resizedImage = drawings_CGImage

    case let .resize(maxPixelSize):
      
      EngineLog.debug(.renderer, "Resizing with maxPixelSize: \(maxPixelSize)")

      let targetSize = Geometry.sizeThatAspectFit(
        size: drawings_CGImage.size,
        maxPixelSize: maxPixelSize
      )

      let context = try CGContext.makeContext(for: drawings_CGImage, size: targetSize)
        .perform { c in
          c.draw(drawings_CGImage, in: c.boundingBoxOfClipPath)
        }

      resizedImage = try context.makeImage().unwrap()
    }
    
    /*
     ===
     ===
     ===
     */
    
    
    EngineLog.debug(.renderer, "Rotates image if needed")

    let rotatedImage = try resizedImage.makeRotatedIfNeeded(rotation: crop.rotation)

    return rotatedImage
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

    var rotatedSize: CGSize = size
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
