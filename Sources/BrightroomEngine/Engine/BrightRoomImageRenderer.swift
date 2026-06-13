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

import BrightroomParametric

@available(*, deprecated, renamed: "BrightRoomImageRenderer", message: "Renamed in favor of SwiftUI.ImageRenderer")
public typealias ImageRenderer = BrightRoomImageRenderer

/// It renders an image with options
public final class BrightRoomImageRenderer {

  public struct Options {

    public var resolution: Resolution
    public var workingFormat: CIFormat
        
    /// An colorspace that uses on rendering.
    /// Result image would use this colorspace.
    /// Nil means letting the renderer use the intrinsic colorspace of the working image.
    public var workingColorSpace: CGColorSpace?
    
    ///
    /// - Parameters:
    ///   - resolution:
    ///   - workingFormat:
    ///   - workingColorSpace:
    public init(
      resolution: BrightRoomImageRenderer.Resolution = .full,
      workingFormat: CIFormat = .BGRA8,
      workingColorSpace: CGColorSpace? = nil
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
      UIImage(cgImage: cgImage, scale: 1, orientation: .up)
        .withRenderingMode(.alwaysOriginal)
    }

    @available(iOS 13.0, *)
    public var swiftUIImage: SwiftUI.Image {
      .init(decorative: cgImage, scale: 1, orientation: .up)
    }

    init(cgImage: CGImage, options: Options, engine: Engine) {
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

  enum RenderingDevice {
    /// GPU rendering, falling back to software rendering when the image
    /// exceeds the GPU context's maximum input or output size.
    case automatic
    /// CPU-based rendering (`.useSoftwareRenderer`).
    case software
    /// GPU rendering with no size-limit fallback.
    case gpu
  }

  /// Internal hook for tests to compare GPU and software rendering output.
  var renderingDevice: RenderingDevice = .automatic

  public enum Resolution {
    case full
    case resize(maxPixelSize: CGFloat)
  }

  /// One pixel-transforming step, applied in array order.
  public enum Operation {
    case effects(EffectPipeline)
    case localAdjustment(LocalAdjustmentFeature)
  }

  public struct Edit {
    public var croppingRect: EditingCrop?

    /// Ordered pixel operations compiled from the editing document, evaluated
    /// in array order through the BrightroomParametric vocabulary.
    public var operations: [Operation] = []

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
        let rendered = try self.render(options: options)
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
    if edit.drawer.isEmpty,
       edit.operations.isEmpty,
       options.workingColorSpace == nil
    {
      return try renderOnlyCropping(options: options)
    } else {
      return try renderRevison2(options: options)
    }
  }

  /**
   Render for only cropping using CoreGraphics
   */
  private func renderOnlyCropping(options: Options = .init()) throws -> Rendered {
    
    assert(options.workingColorSpace == nil, "This rendering operation no supports working with specifying colorspace.")

    EngineLog.debug(.renderer, "Start render in using CoreGraphics")

    /*
     - load original image
     - the image might not be suitable for rendering by orientation wise.
     */
    EngineLog.debug(.renderer, "Load full resolution CGImage from ImageSource.")

    let sourceCGImage: CGImage = source.loadOriginalCGImage()

    /*
     - Fix the image orientation
     */
    EngineLog.debug(.renderer, "Fix orientation")

    let orientedImage = try sourceCGImage.oriented(orientation)

    /*
     - Crops image
     - Uses specified data
     - Uses full size crop info if there's no request.
     */

    let crop: EditingCrop = edit.croppingRect ?? EditingCrop(
      imageSize: source
        .readImageSize()
        .applying(cgOrientation: orientation) // TODO: Better management of orientation
    )

    let renderCrop = RenderCrop(crop, imageSize: orientedImage.size)

    EngineLog.debug(.renderer, "Crop CGImage with extent \(renderCrop)")

    /// Render image as full size
    let croppedImage = try orientedImage.croppedWithColorspace(
      to: renderCrop
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

    return .init(cgImage: resizedImage, options: options, engine: .coreGraphics)
  }

  /**
   Render for full features using CoreImage and CoreGraphics
   */
  private func renderRevison2(
    options: Options = .init(),
    debug: @escaping (CIImage) -> Void = { _ in }
  ) throws -> Rendered {

    let startTime = CACurrentMediaTime()

    /*
     ===
     ===
     ===
     */
    EngineLog.debug(.renderer, "Take full resolution CIImage from ImageSource.")

    let sourceCIImage: CIImage = source.makeOriginalCIImage().oriented(orientation)

    let ciContext = Self.makeCIContext(
      workingFormat: options.workingFormat,
      device: renderingDevice,
      imageExtent: sourceCIImage.extent
    )

    EngineLog.debug(.renderer, "Start render in v2 using CIContext => \(ciContext)")

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

    // Operations are evaluated in document order: a later effects feature can
    // legitimately follow a local adjustment.
    let effected_CIImage = try edit.operations.reduce(sourceCIImage) { image, operation in
      switch operation {
      case .effects(let pipeline):
        return try pipeline.apply(to: image, context: EngineParametricEvaluation.context)
      case .localAdjustment(let adjustment):
        return try adjustment.engineRender(over: image)
      }
    }

    /**
     To keep wide-color(DisplayP3), use createCGImage instead drawing with CIContext
     */
    let effected_CGImage = ciContext.createCGImage(
      effected_CIImage,
      from: effected_CIImage.extent,
      format: options.workingFormat,
      colorSpace: options.workingColorSpace ?? sourceCIImage.colorSpace,
      deferred: false
    )!

    let drawings_CGImage: CGImage

    if edit.drawer.isEmpty {
      EngineLog.debug(.renderer, "No drawings")

      drawings_CGImage = effected_CGImage
    } else {
      EngineLog.debug(.renderer, "Found drawings")
      /**
       Render drawings
       */
      drawings_CGImage = try CGContext.makeContext(for: effected_CGImage)
        .perform { c in

          c.draw(
            effected_CGImage,
            in: .init(origin: .zero, size: effected_CGImage.size)
          )

          self.edit.drawer.forEach { drawer in
            drawer.draw(in: c)
          }

        }
        .makeImage()
        .unwrap()
    }

    let crop: EditingCrop = edit.croppingRect ?? EditingCrop(
      imageSize: source
        .readImageSize()
        .applying(cgOrientation: orientation) // TODO: Better management of orientation
    )
    let renderCrop = RenderCrop(crop, imageSize: drawings_CGImage.size)

    /// Render image as full size
    let croppedImage = try drawings_CGImage.croppedWithColorspace(
      to: renderCrop
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

    let duration = CACurrentMediaTime() - startTime
    EngineLog.debug(.renderer, "Rendering has completed - took \(duration * 1000)ms")

    return .init(cgImage: resizedImage, options: options, engine: .combined)

  }

  private struct CIContextCacheKey: Hashable {
    let workingFormatRawValue: Int32
    let useSoftwareRenderer: Bool
  }

  private static let ciContextCacheLock = NSLock()
  private static var ciContextCache: [CIContextCacheKey: CIContext] = [:]

  /// CIContext creation costs tens to hundreds of milliseconds; CIContext is
  /// thread-safe, so contexts are shared across renders keyed by the options
  /// that affect their output.
  private static func sharedCIContext(
    workingFormat: CIFormat,
    useSoftwareRenderer: Bool
  ) -> CIContext {
    let key = CIContextCacheKey(
      workingFormatRawValue: workingFormat.rawValue,
      useSoftwareRenderer: useSoftwareRenderer
    )

    ciContextCacheLock.lock()
    defer { ciContextCacheLock.unlock() }

    if let cached = ciContextCache[key] {
      return cached
    }

    let context = CIContext(
      options: [
        .workingFormat: workingFormat,
        .highQualityDownsample: true,
        .useSoftwareRenderer: useSoftwareRenderer,
        .cacheIntermediates: false
      ]
    )
    ciContextCache[key] = context
    return context
  }

  private static func makeCIContext(
    workingFormat: CIFormat,
    device: RenderingDevice,
    imageExtent: CGRect
  ) -> CIContext {

    switch device {
    case .software:
      return sharedCIContext(workingFormat: workingFormat, useSoftwareRenderer: true)
    case .gpu:
      return sharedCIContext(workingFormat: workingFormat, useSoftwareRenderer: false)
    case .automatic:
      let gpuContext = sharedCIContext(workingFormat: workingFormat, useSoftwareRenderer: false)

      // GPU contexts are bounded by Metal texture size limits (typically 8192–16384px).
      let inputLimit = gpuContext.inputImageMaximumSize()
      let outputLimit = gpuContext.outputImageMaximumSize()

      if imageExtent.width <= min(inputLimit.width, outputLimit.width),
         imageExtent.height <= min(inputLimit.height, outputLimit.height)
      {
        return gpuContext
      }

      EngineLog.debug(
        .renderer,
        "Image size \(imageExtent.size) exceeds GPU limits (input: \(inputLimit), output: \(outputLimit)); falling back to software renderer."
      )
      return sharedCIContext(workingFormat: workingFormat, useSoftwareRenderer: true)
    }
  }
}
