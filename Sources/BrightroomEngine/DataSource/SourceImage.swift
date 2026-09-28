//
// Copyright (c) 2026 Muukii <muukii.app@gmail.com>
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
import UIKit

#if canImport(Photos)
import Photos
#endif

/// Errors thrown while creating a `SourceImage`.
public enum SourceImageError: Error {

  /// The URL passed as a local file is not a file URL.
  case notFileURL(URL)

  /// The data or file cannot be read as an image, or its pixel size cannot be
  /// determined.
  case unreadableImage

  /// The Photos library could not provide the asset's image data.
  case assetUnavailable(underlyingError: (any Error)?)
}

/// The image a document is authored over.
///
/// A source image is a lightweight value: it references encoded data, a
/// local file, or a decoded bitmap, and knows its orientation and oriented
/// pixel size from the moment it is created. Encoded data and files are
/// decoded only when something renders or prepares the image.
///
/// Features of a document are authored in the image's oriented pixel
/// coordinates, whose extent is `CGRect(origin: .zero, size: pixelSize)`.
///
/// Two source images are equal when they are the same load: copies of a
/// value are equal, and loading the same file twice gives two different
/// images. Comparing is constant time whatever the image size. Keep the
/// value you loaded (for example in a document) instead of loading again.
public struct SourceImage: Hashable, Sendable {

  /// The pixel size with the orientation applied: the domain features of
  /// this image are authored in.
  public var pixelSize: CGSize {
    storage.pixelSize
  }

  let storage: Storage

  init(storage: Storage) {
    self.storage = storage
  }

  public static func == (lhs: SourceImage, rhs: SourceImage) -> Bool {
    lhs.storage === rhs.storage
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(storage))
  }

  /// The image with its orientation applied and a zero origin.
  ///
  /// - Parameter maxPixelSize: The largest length of the returned image's
  ///   longer side, in pixels. The image is never upsampled. When nil, the
  ///   image is the full-resolution, lazily decoded input documents render
  ///   over.
  public func makeCIImage(maxPixelSize: CGFloat? = nil) -> CIImage {
    storage.makeOrientedCIImage(maxPixelSize: maxPixelSize)
  }
}

// MARK: - Loading

extension SourceImage {

  /// Creates an image that reads encoded image data, such as JPEG, HEIF, or
  /// PNG. The data is kept and decoded when needed.
  public init(data: Data) throws {
    guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
      throw SourceImageError.unreadableImage
    }
    try self.init(imageSource: imageSource)
  }

  /// Creates an image that reads a local file when needed.
  ///
  /// The file must stay in place and unchanged for as long as a document
  /// renders from this image.
  public init(contentsOf fileURL: URL) throws {
    guard fileURL.isFileURL else {
      throw SourceImageError.notFileURL(fileURL)
    }
    guard let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
      throw SourceImageError.unreadableImage
    }
    try self.init(imageSource: imageSource)
  }

  /// Creates an image from decoded pixels, oriented by `orientation`.
  public init(cgImage: CGImage, orientation: CGImagePropertyOrientation = .up) {
    self.init(storage: Storage(bitmap: cgImage, orientation: orientation))
  }

  /// Creates an image from a bitmap-backed `UIImage`, oriented by its
  /// `imageOrientation`.
  ///
  /// The decoded pixels stay in memory for as long as the value lives.
  /// Prefer `init(contentsOf:)` or `init(data:)` for large images.
  ///
  /// - Precondition: `image.cgImage` is not nil.
  public init(image: UIImage) {
    precondition(image.cgImage != nil, "SourceImage(image:) requires a bitmap-backed UIImage.")
    let decoded = ImageDecoding.makeDecodedCGImage(from: image.cgImage!) ?? image.cgImage!
    self.init(cgImage: decoded, orientation: CGImagePropertyOrientation(image.imageOrientation))
  }

  /// Creates an image by developing RAW data with Core Image's default RAW
  /// settings.
  ///
  /// The RAW data is developed here, once and synchronously; the value keeps
  /// the developed pixels, already oriented. Developing takes hundreds of
  /// milliseconds for a 12 MP RAW and more for larger ones, so call this off
  /// the main actor.
  public init(rawData: Data) throws {
    guard let filter = CIFilter(imageData: rawData, options: [:]) else {
      throw SourceImageError.unreadableImage
    }
    try self.init(developing: filter)
  }

  /// Creates an image by developing a local RAW file with Core Image's
  /// default RAW settings.
  ///
  /// The file is developed here, once and synchronously; the value keeps the
  /// developed pixels, already oriented, and does not read the file again.
  /// Like `init(rawData:)`, call this off the main actor.
  public init(rawContentsOf fileURL: URL) throws {
    guard fileURL.isFileURL else {
      throw SourceImageError.notFileURL(fileURL)
    }
    guard let filter = CIFilter(imageURL: fileURL, options: [:]) else {
      throw SourceImageError.unreadableImage
    }
    try self.init(developing: filter)
  }

  /// Shared by every RAW development: creating a context is costly, and a
  /// context is safe to use from several threads.
  private static let rawDevelopmentContext = CIContext()

  private init(developing rawFilter: CIFilter) throws {
    guard
      let output = rawFilter.outputImage,
      output.extent.isInfinite == false,
      output.extent.isEmpty == false,
      let developed = Self.rawDevelopmentContext.createCGImage(output, from: output.extent)
    else {
      throw SourceImageError.unreadableImage
    }
    self.init(cgImage: developed, orientation: .up)
  }

  private init(imageSource: CGImageSource) throws {
    guard let metadata = ImageDecoding.makeImageMetadata(from: imageSource) else {
      throw SourceImageError.unreadableImage
    }
    self.init(
      storage: Storage(
        imageSource: imageSource,
        orientation: metadata.orientation,
        pixelSize: metadata.pixelSize
      )
    )
  }
}

#if canImport(Photos)
extension SourceImage {

  /// Requests the current version of a Photos asset's image data, from the
  /// network when needed, and keeps it.
  ///
  /// Cancelling the calling task cancels the request.
  public init(asset: PHAsset) async throws {
    let options = PHImageRequestOptions()
    options.deliveryMode = .highQualityFormat
    options.isNetworkAccessAllowed = true
    options.version = .current

    let requestID = PhotosRequestID()
    let data: Data = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        requestID.value = PHImageManager.default().requestImageDataAndOrientation(
          for: asset,
          options: options
        ) { data, _, _, info in
          if let data {
            continuation.resume(returning: data)
          } else {
            continuation.resume(
              throwing: SourceImageError.assetUnavailable(
                underlyingError: info?[PHImageErrorKey] as? any Error
              )
            )
          }
        }
      }
    } onCancel: {
      requestID.cancel()
    }
    try self.init(data: data)
  }
}

/// The in-flight Photos request, cancelled from the cancellation handler.
private final class PhotosRequestID: @unchecked Sendable {
  private let lock = NSLock()
  private var _value: PHImageRequestID?

  var value: PHImageRequestID? {
    get { lock.withLock { _value } }
    set { lock.withLock { _value = newValue } }
  }

  func cancel() {
    if let value {
      PHImageManager.default().cancelImageRequest(value)
    }
  }
}
#endif

// MARK: - Storage

extension SourceImage {

  /// The immutable backing of a source image, shared by its copies.
  ///
  /// `@unchecked Sendable`: every stored property is immutable after init, and
  /// the Core Graphics and ImageIO objects it holds are thread-safe for
  /// reading.
  final class Storage: @unchecked Sendable {

    enum Backing {
      /// Encoded data or a file, read through ImageIO.
      case imageSource(CGImageSource)
      /// Decoded pixels, including developed RAW images.
      case bitmap(CGImage)
    }

    let backing: Backing

    /// The orientation applied to the unoriented pixels.
    let orientation: CGImagePropertyOrientation

    let pixelSize: CGSize

    init(imageSource: CGImageSource, orientation: CGImagePropertyOrientation, pixelSize: CGSize) {
      self.backing = .imageSource(imageSource)
      self.orientation = orientation
      self.pixelSize = pixelSize
    }

    init(bitmap: CGImage, orientation: CGImagePropertyOrientation) {
      self.backing = .bitmap(bitmap)
      self.orientation = orientation
      self.pixelSize = CGSize(width: bitmap.width, height: bitmap.height)
        .applying(cgOrientation: orientation)
    }

    /// The unoriented, full-resolution pixels as a lazy Core Image recipe.
    func makeUnorientedCIImage() -> CIImage {
      switch backing {
      case .imageSource(let imageSource):
        return CIImage(cgImageSource: imageSource, index: 0, options: [:])
      case .bitmap(let cgImage):
        return CIImage(cgImage: cgImage)
      }
    }

    /// Unoriented pixels downsampled so that the SHORT side is at most
    /// `shortSideLength`, as the editing source is prepared. See
    /// `ImageDecoding.makeResizedCGImage(from:shortSideLength:)`.
    func makeResizedCGImage(shortSideLength: CGFloat) -> CGImage? {
      switch backing {
      case .imageSource(let imageSource):
        return ImageDecoding.makeResizedCGImage(
          from: imageSource,
          shortSideLength: shortSideLength
        )
      case .bitmap(let cgImage):
        return ImageDecoding.makeResizedCGImage(from: cgImage, shortSideLength: shortSideLength)
      }
    }

    func makeOrientedCIImage(maxPixelSize: CGFloat?) -> CIImage {
      let image: CIImage
      if let maxPixelSize, max(pixelSize.width, pixelSize.height) > maxPixelSize {
        image = makeDownsampledOrientedCIImage(maxPixelSize: maxPixelSize)
      } else {
        image = makeUnorientedCIImage().oriented(orientation)
      }
      return image.transformed(
        by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)
      )
    }

    private func makeDownsampledOrientedCIImage(maxPixelSize: CGFloat) -> CIImage {
      switch backing {
      case .imageSource(let imageSource):
        let options: [CFString: Any] = [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
          kCGImageSourceCreateThumbnailWithTransform: false,
          kCGImageSourceShouldCacheImmediately: true,
        ]
        if let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) {
          return CIImage(cgImage: thumbnail).oriented(orientation)
        }
      case .bitmap:
        break
      }
      let scale = maxPixelSize / max(pixelSize.width, pixelSize.height)
      return makeUnorientedCIImage()
        .oriented(orientation)
        .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }
  }
}
