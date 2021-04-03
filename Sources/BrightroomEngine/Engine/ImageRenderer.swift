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

    public var resolution: Resolution
    public var workingFormat: CIFormat
    public var workingColorSpace: CGColorSpace

    public init(
      resolution: ImageRenderer.Resolution = .full,
      workingFormat: CIFormat = .ARGB8,
      workingColorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    ) {
      self.resolution = resolution
      self.workingFormat = workingFormat
      self.workingColorSpace = workingColorSpace
    }

  }

  /**
   A result of rendering.
   */
  public struct Rendered {

    public enum Engine {
      case coreGraphics
      case combined
    }

    public enum DataType {
      case jpeg(quality: CGFloat)
      case png
    }

    /// A type of engine how rendered by
    public let engine: Engine

    /// An Options instance that used in redering.
    public let options: Options

    /// A rendered image that working on specified color-space.
    /// Orientation fixed.
    public let cgImage: CGImage

    public var uiImage: UIImage {
      UIImage.init(cgImage: cgImage, scale: 1, orientation: .up)
    }

    @available(iOS 13.0, *)
    public var swiftUIImage: SwiftUI.Image {
      .init(decorative: cgImage, scale: 1, orientation: .up)
    }

    init(cgImage: CGImage, options: Options, engine: Engine) {
      assert(cgImage.colorSpace == options.workingColorSpace)
      self.cgImage = cgImage
      self.options = options
      self.engine = engine
    }

    /**
     Makes a data of the image that optimized for sharing.

     Since the rendered image is working on DisplayP3 profile, that data might display wrong color on other platform devices.
     To avoid those issues, use this method to create data to send instead of creating data from `cgImageDisplayP3`.
     */
    public func makeOptimizedForSharingData(dataType: DataType) -> Data {
      switch dataType {
      case .jpeg(let quality):
        return ImageTool.makeImageForJPEGOptimizedSharing(image: cgImage, quality: quality)
      case .png:
        return ImageTool.makeImageForPNGOptimizedSharing(image: cgImage)
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
    public var modifiers: [AnyFilter] = []
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

  /// Renders the image according edits asynchronously
  ///
  /// - Parameters:
  ///   - options:
  ///   - callbackQueue: A queue that completion closure runs on.
  ///   - completion: A closure that runs on rendering completed.
  public func render(
    options: Options = .init(),
    callbackQueue: DispatchQueue = .main,
    completion: @escaping (
      Result<Rendered, Error>
    ) -> Void
  ) {
    type(of: self).queue.async {
      do {
        let rendered = try self.render()
        callbackQueue.async {
          completion(.success(rendered))
        }
      } catch {
        callbackQueue.async {
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
    EngineLog.debug(
      .renderer,
      "Fixing colorspace \(sourceCGImage.colorSpace?.name as NSString? ?? "") -> \(options.workingColorSpace.name as NSString? ?? "")"
    )

    let fixedColorspace: CGImage = try sourceCGImage.copy(colorSpace: options.workingColorSpace)
      .unwrap(orThrow: "Failed to copy with fixing colorspace.")

    assert(fixedColorspace.colorSpace == options.workingColorSpace)
    /*
     ===
     ===
     ===
     */
    EngineLog.debug(.renderer, "Fix orientation")

    let orientedImage = try fixedColorspace.oriented(orientation)

    /*
     ===
     ===
     ===
     */
    // TODO: Better management of orientation
    let crop = edit.croppingRect ?? .init(imageSize: source.readImageSize().applying(cgOrientation: orientation))
    EngineLog.debug(.renderer, "Crop CGImage with extent \(crop)")

    let croppedImage = try orientedImage.croppedWithColorspace(to: crop.cropExtent)

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

    let rotatedImage = try resizedImage.rotated(rotation: crop.rotation)

    return .init(cgImage: rotatedImage, options: options, engine: .coreGraphics)
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
        .useSoftwareRenderer: true,
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

    // TODO: Better management of orientation
    let crop = edit.croppingRect ?? .init(imageSize: source.readImageSize().applying(cgOrientation: orientation))

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

    let rotatedImage = try resizedImage.rotated(rotation: crop.rotation)

    let duration = CACurrentMediaTime() - startTime
    EngineLog.debug(.renderer, "Rendering has completed - took \(duration * 1000)ms")

    return .init(cgImage: rotatedImage, options: options, engine: .combined)

  }
}
