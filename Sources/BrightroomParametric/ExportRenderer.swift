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
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif

/// Materializes a feature from a source `CIImage` into a concrete result
/// (`RenderedImage`), either an in-memory bitmap or a file on disk.
///
/// This is the export/preview evaluation layer of the parametric stack: the
/// root feature (effects, local adjustments, and crops) evaluates to one lazy
/// `CIImage` recipe through `FeatureRenderer`,
/// which Core Image then evaluates here at the requested quality, resolution,
/// and output. The source image is expected to be already oriented; callers
/// holding an unoriented loader should apply orientation before rendering.
public struct ExportRenderer {

  /// An encoded file format for `Output.file`.
  public enum FileType: Sendable {
    /// Lossy JPEG. `quality` is 0...1 (1 = best).
    case jpeg(quality: CGFloat)
    /// HEIF (HEIC). `quality` is 0...1 (1 = best).
    case heif(quality: CGFloat)
    /// Lossless PNG.
    case png
  }

  /// Where a render stores its result.
  public enum Output: Sendable {
    /// Render into an in-memory bitmap (a full-resolution `CGImage`). Simple,
    /// but allocates the whole output buffer (≈ W·H·4 bytes; ~576MB at 12000²).
    case memory
    /// Stream the render straight to a file via Core Image's tiled writer — no
    /// full-resolution `CGImage`, peak memory bounded to ~a tile plus encoder
    /// state. The right choice for very large images.
    case file(url: URL, fileType: FileType)
  }

  public struct Options: Sendable {

    public var resolution: Resolution

    /// The pixel format of the delivered result (the `CGImage` or the file).
    ///
    /// Processing always runs in a half-float working buffer; this is only the
    /// output format.
    public var outputFormat: CIFormat

    /// The color space the result is tagged with.
    ///
    /// `nil` uses the source image's own color space.
    public var outputColorSpace: CGColorSpace?

    /// Where the result is stored (in-memory bitmap or a file on disk).
    public var output: Output

    ///
    /// - Parameters:
    ///   - resolution:
    ///   - outputFormat:
    ///   - outputColorSpace:
    ///   - output: In-memory bitmap (`.memory`, default) or a tiled write to a
    ///     file (`.file`). Either way the result is returned as a `RenderedImage`.
    public init(
      resolution: Resolution = .full,
      outputFormat: CIFormat = .BGRA8,
      outputColorSpace: CGColorSpace? = nil,
      output: Output = .memory
    ) {
      self.resolution = resolution
      self.outputFormat = outputFormat
      self.outputColorSpace = outputColorSpace
      self.output = output
    }

  }

  /// Where Core Image renders. Package access, so Brightroom's tests can
  /// compare devices; the public `render` always uses `.automatic`.
  package enum Device: Sendable {
    /// GPU rendering, asking for Core Image's software renderer when the
    /// image exceeds the GPU context's maximum input or output size. On
    /// iOS 26 (checked on the Simulator) that renderer also runs on Metal
    /// and reports the same limits, so the fallback does not raise them.
    case automatic
    /// CPU-based rendering (`.useSoftwareRenderer`).
    case software
    /// GPU rendering with no size-limit fallback.
    case gpu
  }

  public enum Resolution: Sendable {
    case full
    case resize(maxPixelSize: CGFloat)
  }

  private let featureRenderer = FeatureRenderer()

  /// Creates an export renderer.
  public init() {}

  /**
   Renders a feature over an already-oriented source image.

   Single rendering path: the root feature (effects, local adjustments, and
   crops) evaluates to one `CIImage` recipe through `FeatureRenderer`, with
   `sourceImage` as the chain entry, which Core Image then materializes. An
   unedited image or a pure crop is just an `EmptyFeature()` or crop-only
   feature on the same path.

   The result is returned as a `RenderedImage`, which hides whether it is backed by an
   in-memory bitmap or a file — controlled by `options.output`:

   - `.memory` materializes a full-resolution `CGImage` (`createCGImage`).
   - `.file` streams the render to disk through Core Image's tiled writer (no
     full-resolution `CGImage`; bounded peak memory) — use it for large images.

   Core Image renders on the GPU. When the image exceeds the GPU context's
   maximum input or output size, it asks for Core Image's software renderer;
   on iOS 26 (checked on the Simulator) that renderer also runs on Metal and
   reports the same limits, so this does not raise them.

   This call is synchronous; callers that need to stay off an actor should hop
   to their own queue first.
   */
  public func render(
    from sourceImage: CIImage,
    feature: some Feature,
    options: Options = .init()
  ) throws -> RenderedImage {
    try render(from: sourceImage, feature: feature, options: options, device: .automatic)
  }

  /// Renders on a chosen device. See `render(from:feature:options:)`.
  package func render(
    from sourceImage: CIImage,
    feature: some Feature,
    options: Options,
    device: Device
  ) throws -> RenderedImage {

    let outputCIImage = try featureRenderer.makeImage(from: sourceImage, feature: feature)
    let colorSpace = options.outputColorSpace ?? sourceImage.colorSpace

    // Always process through a half-float WORKING buffer so wide-gamut and
    // out-of-range (>1 / <0) values survive the multi-filter chain — an 8-bit
    // working format would clamp/band them mid-chain. This is the processing
    // precision only; it is independent of the OUTPUT format below, which stays
    // `options.outputFormat` (the caller's delivery format — 8-bit Display-P3
    // is fine for SDR; bumping the output to float is a per-call delivery choice).
    let ciContext = Self.makeCIContext(
      workingFormat: .RGBAh,
      device: device,
      imageExtent: sourceImage.extent
    )

    // `Resolution.resize` is a Core Image scale on the recipe, so the downscale
    // is part of the same (tiled) evaluation for both outputs.
    let image = Self.scaled(outputCIImage, for: options.resolution)

    switch options.output {
    case .memory:
      /// To keep wide-color(DisplayP3), use createCGImage instead drawing with CIContext
      guard let cgImage = ciContext.createCGImage(
        image,
        from: image.extent,
        format: options.outputFormat,
        colorSpace: colorSpace,
        deferred: false
      ) else {
        throw ExportRendererError.failedToCreateCGImage(extent: image.extent)
      }
      return .init(cgImage: cgImage, options: options)

    case let .file(url, fileType):
      // Hand the recipe straight to Core Image's tiled writer — no
      // full-resolution `CGImage`, no `CGImageDestination`. Peak memory is
      // bounded to ~a tile plus the encoder state.
      try Self.write(
        image,
        to: url,
        fileType: fileType,
        context: ciContext,
        // The write APIs require a concrete color space; fall back to sRGB when
        // the source has none (mirrors `createCGImage(colorSpace: nil)`).
        colorSpace: colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
      )
      return .init(fileURL: url, options: options)
    }
  }

  private static func write(
    _ image: CIImage,
    to url: URL,
    fileType: FileType,
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
  // Guarded by ciContextCacheLock; the lock makes access race-free, so opt out
  // of the Swift 6 global-mutable-state check rather than re-isolating.
  private nonisolated(unsafe) static var ciContextCache: [CIContextCacheKey: CIContext] = [:]

  /// Extended-linear, wide-gamut (Display-P3 primaries) CIContext WORKING space.
  /// Paired with the half-float working format, this extended space lets
  /// out-of-sRGB / out-of-range values survive the filter chain, so edited
  /// wide-gamut sources (Display-P3, Adobe RGB, ...) export faithfully instead
  /// of being gamut-clipped into the default sRGB-primary working space. It
  /// matches the editing canvas working space so canvas and export agree.
  /// (Distinct from `Options.outputColorSpace`, which is the OUTPUT tag.)
  private static let processingColorSpace =
    CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) ?? CGColorSpaceCreateDeviceRGB()

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
        .workingColorSpace: processingColorSpace,
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
    device: Device,
    imageExtent: CGRect
  ) -> CIContext {

    switch device {
    case .software:
      return sharedCIContext(workingFormat: workingFormat, useSoftwareRenderer: true)
    case .gpu:
      return sharedCIContext(workingFormat: workingFormat, useSoftwareRenderer: false)
    case .automatic:
      let gpuContext = sharedCIContext(workingFormat: workingFormat, useSoftwareRenderer: false)

      #if canImport(UIKit)
      // GPU contexts are bounded by Metal texture size limits (typically 8192–16384px).
      // The input/output max-size queries are unavailable on native macOS.
      let inputLimit = gpuContext.inputImageMaximumSize()
      let outputLimit = gpuContext.outputImageMaximumSize()

      if imageExtent.width <= min(inputLimit.width, outputLimit.width),
         imageExtent.height <= min(inputLimit.height, outputLimit.height)
      {
        return gpuContext
      }

      return sharedCIContext(workingFormat: workingFormat, useSoftwareRenderer: true)
      #else
      return gpuContext
      #endif
    }
  }
}

/// Errors thrown by `ExportRenderer`, by its file writer, and by reading a
/// `RenderedImage`.
///
/// Every failure the export path raises is one of these cases, so callers can
/// match a thrown error with `==` or `switch`.
public enum ExportRendererError: Error, Equatable, LocalizedError, Sendable {

  /// A step of writing `ExportRenderer.Output.file`.
  public enum WriteStep: Equatable, Sendable {
    /// The image extent is empty, infinite, or smaller than one pixel.
    case validatingExtent
    /// The disk-backed scratch buffer could not be created.
    case creatingScratchFile
    /// The scratch buffer could not be mapped into memory.
    case mappingScratchFile
    /// Core Graphics could not wrap the scratch buffer.
    case creatingDataProvider
    /// Core Graphics could not create an image over the scratch buffer.
    case creatingImage
    /// Image I/O could not create a destination for the file type.
    case creatingDestination
    /// Image I/O could not finish encoding the file.
    case finalizing
  }

  /// A file-backed render could not be decoded back into a `CGImage`.
  case failedToDecodeRenderedFile(URL)

  /// A memory-backed render could not allocate a `CGImage` for the extent.
  ///
  /// Most likely at the sizes `ExportRenderer.Output.file` exists to avoid.
  case failedToCreateCGImage(extent: CGRect)

  /// Writing the file at the URL failed at `step`.
  case fileWriteFailed(URL, step: WriteStep)

  /// Image I/O could not encode the result for `RenderedImage.sharingData(as:)`.
  case sharingDataEncodingFailed

  public var errorDescription: String? {
    switch self {
    case let .failedToDecodeRenderedFile(url):
      "The rendered file at \(url.path) couldn't be decoded."
    case let .failedToCreateCGImage(extent):
      "Core Image couldn't create an image of \(extent.width) × \(extent.height) pixels."
    case let .fileWriteFailed(url, step):
      "Writing the rendered file at \(url.path) failed while \(step.description)."
    case .sharingDataEncodingFailed:
      "The rendered image couldn't be encoded for sharing."
    }
  }
}

extension ExportRendererError.WriteStep: CustomStringConvertible {

  public var description: String {
    switch self {
    case .validatingExtent: "validating the image extent"
    case .creatingScratchFile: "creating the scratch file"
    case .mappingScratchFile: "mapping the scratch file"
    case .creatingDataProvider: "creating the data provider"
    case .creatingImage: "creating the image"
    case .creatingDestination: "creating the destination"
    case .finalizing: "finalizing the file"
    }
  }
}

/**
 The result of `ExportRenderer.render(from:feature:options:)`.

 `RenderedImage` hides whether the result lives in memory or on disk: the same type
 is returned for `ExportRenderer.Output.memory` and `ExportRenderer.Output.file`. Ask it for whatever you
 need (`cgImage`, `uiImage`, `fileURL`, `thumbnail`) and it resolves the
 backing for you.
 */
public struct RenderedImage: Sendable {

  enum Storage: Sendable {
    case memory(CGImage)
    case file(URL)
  }

  /// The options the result was rendered with.
  public let options: ExportRenderer.Options

  private let storage: Storage

  init(cgImage: CGImage, options: ExportRenderer.Options) {
    self.storage = .memory(cgImage)
    self.options = options
  }

  init(fileURL: URL, options: ExportRenderer.Options) {
    self.storage = .file(fileURL)
    self.options = options
  }

  /// The on-disk location when the render targeted `ExportRenderer.Output.file`; `nil` for an
  /// in-memory render.
  public var fileURL: URL? {
    if case .file(let url) = storage { return url }
    return nil
  }

  /// The result as a `CGImage`, orientation fixed and tagged with the working
  /// color space. An in-memory render returns immediately; a file-backed
  /// render decodes the file (which loads the full image into memory — avoid
  /// it on the large exports `ExportRenderer.Output.file` exists to keep bounded).
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
          throw ExportRendererError.failedToDecodeRenderedFile(url)
        }
        return image
      }
    }
  }

  #if canImport(UIKit)
  public var uiImage: UIImage {
    get throws {
      UIImage(cgImage: try cgImage, scale: 1, orientation: .up)
        .withRenderingMode(.alwaysOriginal)
    }
  }
  #endif

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
        throw ExportRendererError.failedToDecodeRenderedFile(url)
      }
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        kCGImageSourceShouldCacheImmediately: true,
      ]
      guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        throw ExportRendererError.failedToDecodeRenderedFile(url)
      }
      return image
    }
  }

  /// Encodes the result for sharing with other devices and apps.
  ///
  /// The data is converted for sharing
  /// (`kCGImageDestinationOptimizeColorForSharing`), so a wide-gamut result
  /// displays correctly on devices that do not manage color. Use it instead of
  /// encoding `cgImage` yourself when the data leaves the app.
  ///
  /// - Parameter fileType: The encoding, the same `ExportRenderer.FileType`
  ///   `ExportRenderer.Output.file` takes.
  /// - Throws: `ExportRendererError.sharingDataEncodingFailed` when Image I/O
  ///   cannot encode the image, or the error `cgImage` throws.
  public func sharingData(as fileType: ExportRenderer.FileType) throws -> Data {
    let image = try cgImage
    let data = NSMutableData()

    let utType: UTType
    var properties: [CFString: Any] = [kCGImageDestinationOptimizeColorForSharing: true]
    switch fileType {
    case .jpeg(let quality):
      utType = .jpeg
      properties[kCGImageDestinationLossyCompressionQuality] = quality
    case .heif(let quality):
      utType = .heic
      properties[kCGImageDestinationLossyCompressionQuality] = quality
    case .png:
      utType = .png
    }

    guard
      let destination = CGImageDestinationCreateWithData(
        data,
        utType.identifier as CFString,
        1,
        nil
      )
    else {
      throw ExportRendererError.sharingDataEncodingFailed
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      throw ExportRendererError.sharingDataEncodingFailed
    }
    return data as Data
  }

}
