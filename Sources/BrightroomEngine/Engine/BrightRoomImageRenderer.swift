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
import ImageIO
import SwiftUI
import UIKit

import BrightroomParametric

@available(*, deprecated, renamed: "BrightRoomImageRenderer", message: "Renamed in favor of SwiftUI.ImageRenderer")
public typealias ImageRenderer = BrightRoomImageRenderer

/// It renders an image with options
public final class BrightRoomImageRenderer {

  /// An encoded file format for `Output.file`.
  public enum ExportFileType {
    /// Lossy JPEG. `quality` is 0...1 (1 = best).
    case jpeg(quality: CGFloat)
    /// HEIF (HEIC). `quality` is 0...1 (1 = best).
    case heif(quality: CGFloat)
    /// Lossless PNG.
    case png
  }

  /// Where a render stores its result.
  public enum Output {
    /// Render into an in-memory bitmap (a full-resolution `CGImage`). Simple,
    /// but allocates the whole output buffer (≈ W·H·4 bytes; ~576MB at 12000²).
    case memory
    /// Stream the render straight to a file via Core Image's tiled writer — no
    /// full-resolution `CGImage`, peak memory bounded to ~a tile plus encoder
    /// state. The right choice for very large images.
    case file(url: URL, fileType: ExportFileType)
  }

  public struct Options {

    public var resolution: Resolution
    public var workingFormat: CIFormat

    /// An colorspace that uses on rendering.
    /// Result image would use this colorspace.
    /// Nil means letting the renderer use the intrinsic colorspace of the working image.
    public var workingColorSpace: CGColorSpace?

    /// Where the result is stored (in-memory bitmap or a file on disk).
    public var output: Output

    ///
    /// - Parameters:
    ///   - resolution:
    ///   - workingFormat:
    ///   - workingColorSpace:
    ///   - output: In-memory bitmap (`.memory`, default) or a tiled write to a
    ///     file (`.file`). Either way the result is returned as a `Rendered`.
    public init(
      resolution: BrightRoomImageRenderer.Resolution = .full,
      workingFormat: CIFormat = .BGRA8,
      workingColorSpace: CGColorSpace? = nil,
      output: Output = .memory
    ) {
      self.resolution = resolution
      self.workingFormat = workingFormat
      self.workingColorSpace = workingColorSpace
      self.output = output
    }

  }

  public enum RenderingError: Swift.Error {
    /// A file-backed render could not be decoded back into a `CGImage`.
    case failedToDecodeRenderedFile(URL)
  }

  /**
   A result of rendering.

   `Rendered` hides whether the result lives in memory or on disk: the same type
   is returned for `Output.memory` and `Output.file`. Ask it for whatever you
   need (`cgImage`, `uiImage`, `fileURL`, `thumbnail`) and it resolves the
   backing for you.
   */
  public struct Rendered {

    public enum DataType {
      case jpeg(quality: CGFloat)
      case png
    }

    enum Storage {
      case memory(CGImage)
      case file(URL)
    }

    /// An Options instance that used in redering.
    public let options: Options

    private let storage: Storage

    init(cgImage: CGImage, options: Options) {
      self.storage = .memory(cgImage)
      self.options = options
    }

    init(fileURL: URL, options: Options) {
      self.storage = .file(fileURL)
      self.options = options
    }

    /// The on-disk location when the render targeted `Output.file`; `nil` for an
    /// in-memory render.
    public var fileURL: URL? {
      if case .file(let url) = storage { return url }
      return nil
    }

    /// The result as a `CGImage`, orientation fixed and tagged with the working
    /// color space. An in-memory render returns immediately; a file-backed
    /// render decodes the file (which loads the full image into memory — avoid
    /// it on the large exports `Output.file` exists to keep bounded).
    public var cgImage: CGImage {
      get throws {
        switch storage {
        case .memory(let image):
          return image
        case .file(let url):
          guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
          else {
            throw RenderingError.failedToDecodeRenderedFile(url)
          }
          return image
        }
      }
    }

    public var uiImage: UIImage {
      get throws {
        UIImage(cgImage: try cgImage, scale: 1, orientation: .up)
          .withRenderingMode(.alwaysOriginal)
      }
    }

    @available(iOS 13.0, *)
    public var swiftUIImage: SwiftUI.Image {
      get throws {
        .init(decorative: try cgImage, scale: 1, orientation: .up)
      }
    }

    /// A downsampled decode of the result, capped to `maxPixelSize` on the long
    /// side — preview a large export WITHOUT the full-resolution decode spike.
    /// A file result decodes a thumbnail via Image I/O (bounded memory); an
    /// in-memory result returns the already-resident image unchanged.
    public func thumbnail(maxPixelSize: CGFloat) throws -> CGImage {
      switch storage {
      case .memory(let image):
        return image
      case .file(let url):
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
          throw RenderingError.failedToDecodeRenderedFile(url)
        }
        let options: [CFString: Any] = [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
          kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
          throw RenderingError.failedToDecodeRenderedFile(url)
        }
        return image
      }
    }

    /**
     Makes a data of the image that optimized for sharing.

     Since the rendered image is working on DisplayP3 profile, that data might display wrong color on other platform devices.
     To avoid those issues, use this method to create data to send instead of creating data from `cgImageDisplayP3`.
     */
    public func makeOptimizedForSharingData(dataType: DataType) throws -> Data {
      switch dataType {
      case .jpeg(let quality):
        return ImageTool.makeImageForJPEGOptimizedSharing(image: try cgImage, quality: quality)
      case .png:
        return ImageTool.makeImageForPNGOptimizedSharing(image: try cgImage)
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

  public struct Edit {

    /// The parametric document evaluated by `ParametricImageRenderer`. Crop is
    /// a domain feature inside the document, so export and preview share one
    /// evaluation path.
    public var document: EditingDocument

    public init(document: EditingDocument = .init()) {
      self.document = document
    }
  }

  public let source: ImageSource
  public let orientation: CGImagePropertyOrientation

  public var edit: Edit

  public init(source: ImageSource, orientation: CGImagePropertyOrientation) {
    self.source = source
    self.orientation = orientation
    edit = .init()
  }

  /**
   Renders an image according to the editing.

   Single rendering path: the edit (effects, local adjustments, and the crop as a
   domain feature) compiles to one `CIImage` recipe through
   `ParametricImageRenderer`, which Core Image evaluates. An unedited image or a
   pure crop is just an identity/crop-only document on the same path.

   The result is returned as a `Rendered`, which hides whether it is backed by an
   in-memory bitmap or a file — controlled by `options.output`:

   - `.memory` materializes a full-resolution `CGImage` (`createCGImage`).
   - `.file` streams the render to disk through Core Image's tiled writer (no
     full-resolution `CGImage`; bounded peak memory) — use it for large images.

   The work runs on the renderer's private serial queue, off the calling actor.
   */
  public func render(options: Options = .init()) async throws -> Rendered {
    try await withCheckedThrowingContinuation { continuation in
      Self.queue.async {
        do {
          continuation.resume(returning: try self.renderSynchronously(options: options))
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  /// The synchronous render core shared by `render`. Builds the parametric
  /// `CIImage` recipe once and either materializes a `CGImage` (`.memory`) or
  /// streams it to a file (`.file`). Internal so size-sensitive benchmarks can
  /// measure it without the async hop.
  func renderSynchronously(options: Options) throws -> Rendered {
    let startTime = CACurrentMediaTime()

    let evaluated = try makeEvaluatedCIImage(options: options)
    // `Resolution.resize` is a Core Image scale on the recipe, so the downscale
    // is part of the same (tiled) evaluation for both outputs.
    let image = Self.scaled(evaluated.image, for: options.resolution)

    EngineLog.debug(.renderer, "Start render using CIContext => \(evaluated.context)")
    EngineLog.debug(.renderer, "Evaluate parametric document => \(image)")

    let rendered: Rendered
    switch options.output {
    case .memory:
      /// To keep wide-color(DisplayP3), use createCGImage instead drawing with CIContext
      let cgImage = evaluated.context.createCGImage(
        image,
        from: image.extent,
        format: options.workingFormat,
        colorSpace: evaluated.colorSpace,
        deferred: false
      )!
      rendered = .init(cgImage: cgImage, options: options)

    case let .file(url, fileType):
      // Hand the recipe straight to Core Image's tiled writer — no
      // full-resolution `CGImage`, no `CGImageDestination`. Peak memory is
      // bounded to ~a tile plus the encoder state.
      try Self.write(
        image,
        to: url,
        fileType: fileType,
        context: evaluated.context,
        // The write APIs require a concrete color space; fall back to sRGB when
        // the source has none (mirrors `createCGImage(colorSpace: nil)`).
        colorSpace: evaluated.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
      )
      rendered = .init(fileURL: url, options: options)
    }

    let duration = CACurrentMediaTime() - startTime
    EngineLog.debug(.renderer, "Rendering has completed - took \(duration * 1000)ms")

    return rendered
  }

  private static func write(
    _ image: CIImage,
    to url: URL,
    fileType: ExportFileType,
    context: CIContext,
    colorSpace: CGColorSpace
  ) throws {
    // Bounded-memory write: render the recipe strip-by-strip into a disk-backed
    // (mmap'd) buffer and encode lazily, instead of `write{JPEG,HEIF}Representation`
    // which renders the full bitmap into RAM first. See CIImageStreamingFileWriter.
    try CIImageStreamingFileWriter.write(
      image,
      to: url,
      fileType: fileType,
      context: context,
      colorSpace: colorSpace
    )
  }

  /// Builds the evaluated output `CIImage`, its `CIContext`, and the working
  /// color space — the shared front half of every full-feature render. The
  /// document (effects, local adjustments, crop-as-domain-feature) compiles to
  /// one lazy `CIImage` recipe whose extent is already the cropped, zero-origin
  /// output. `radiusReferenceExtent` is nil because the source here is the full
  /// image at render scale.
  private func makeEvaluatedCIImage(
    options: Options
  ) throws -> (image: CIImage, context: CIContext, colorSpace: CGColorSpace?) {
    EngineLog.debug(.renderer, "Take full resolution CIImage from ImageSource.")
    let sourceCIImage: CIImage = source.makeOriginalCIImage().oriented(orientation)

    let ciContext = Self.makeCIContext(
      workingFormat: options.workingFormat,
      device: renderingDevice,
      imageExtent: sourceCIImage.extent
    )

    let outputCIImage = try ParametricImageRenderer().makeImage(
      from: sourceCIImage,
      document: edit.document
    )

    return (outputCIImage, ciContext, options.workingColorSpace ?? sourceCIImage.colorSpace)
  }

  /// Applies `Resolution.resize` as a Core Image Lanczos scale so the downscale
  /// is part of the tiled recipe (the `CIContext` already has
  /// `.highQualityDownsample`). `.full` returns the image unchanged.
  private static func scaled(_ image: CIImage, for resolution: Resolution) -> CIImage {
    switch resolution {
    case .full:
      return image
    case .resize(let maxPixelSize):
      let extent = image.extent
      let longest = max(extent.width, extent.height)
      guard longest > maxPixelSize, longest > 0 else {
        return image
      }
      let scale = maxPixelSize / longest
      let scaled = image
        .applyingFilter(
          "CILanczosScaleTransform",
          parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0]
        )
      // Lanczos can grow the extent by sub-pixels (filter support); crop back to
      // the integer target so the encoded file has exact dimensions. The
      // parametric output is zero-origin.
      let targetSize = CGSize(
        width: (extent.width * scale).rounded(),
        height: (extent.height * scale).rounded()
      )
      return scaled.cropped(to: CGRect(origin: .zero, size: targetSize))
    }
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
