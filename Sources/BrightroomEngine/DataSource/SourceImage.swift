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

  /// Downloading a remote image failed.
  case downloadFailed(underlyingError: any Error)

  /// The Photos library could not provide the asset's image data.
  case assetUnavailable(underlyingError: (any Error)?)
}

/// The image a document is authored over.
///
/// A source image is a lightweight value: it references encoded data, a
/// local file, a decoded bitmap, or a RAW recipe, and knows its orientation
/// and oriented pixel size from the moment it is created. Pixels are decoded
/// only when something renders or prepares the image.
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
  public init(fileURL: URL) throws {
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
  /// Prefer `init(fileURL:)` or `init(data:)` for large images.
  ///
  /// - Precondition: `image.cgImage` is not nil.
  public init(image: UIImage) {
    precondition(image.cgImage != nil, "SourceImage(image:) requires a bitmap-backed UIImage.")
    let decoded = ImageTool.makeDecodedCGImage(from: image.cgImage!) ?? image.cgImage!
    self.init(cgImage: decoded, orientation: CGImagePropertyOrientation(image.imageOrientation))
  }

  /// Creates an image that develops RAW data with Core Image's RAW filter
  /// when needed. The filter's default orientation and settings apply.
  public init(rawData: Data) throws {
    try self.init(storage: Storage(raw: .data(rawData)))
  }

  /// Creates an image that develops a local RAW file with Core Image's RAW
  /// filter when needed.
  public init(rawFileURL: URL) throws {
    guard rawFileURL.isFileURL else {
      throw SourceImageError.notFileURL(rawFileURL)
    }
    try self.init(storage: Storage(raw: .file(rawFileURL)))
  }

  /// Downloads a remote image and keeps its encoded data.
  public init(remoteURL: URL, session: URLSession = .shared) async throws {
    try await self.init(remoteURLRequest: URLRequest(url: remoteURL), session: session)
  }

  /// Downloads a remote image and keeps its encoded data.
  ///
  /// Cancelling the calling task cancels the download.
  public init(remoteURLRequest: URLRequest, session: URLSession = .shared) async throws {
    let data: Data
    do {
      let (body, response) = try await session.data(for: remoteURLRequest)
      if let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) == false {
        throw URLError(.badServerResponse)
      }
      data = body
    } catch {
      throw SourceImageError.downloadFailed(underlyingError: error)
    }
    try self.init(data: data)
  }

  private init(imageSource: CGImageSource) throws {
    guard let metadata = ImageTool.makeImageMetadata(from: imageSource) else {
      throw SourceImageError.unreadableImage
    }
    self.init(
      storage: Storage(
        imageSource: imageSource,
        orientation: metadata.orientation,
        pixelSize: metadata.imageSize
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

  /// Creates an image that reads the full-size image file of a content
  /// editing input.
  ///
  /// The file belongs to the input; keep the input alive while documents
  /// render from this image.
  public init(contentEditingInput: PHContentEditingInput) throws {
    guard let url = contentEditingInput.fullSizeImageURL else {
      throw SourceImageError.unreadableImage
    }
    try self.init(fileURL: url)
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
  /// reading. RAW filters are created per use and never shared.
  final class Storage: @unchecked Sendable {

    enum RAWInput {
      case data(Data)
      case file(URL)
    }

    enum Backing {
      /// Encoded data or a file, read through ImageIO.
      case imageSource(CGImageSource)
      /// Decoded pixels.
      case bitmap(CGImage)
      /// A RAW recipe developed by Core Image. Its output is already oriented.
      case raw(RAWInput)
    }

    let backing: Backing

    /// The orientation applied to the unoriented pixels; `.up` for RAW,
    /// whose developed output is oriented.
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

    init(raw: RAWInput) throws {
      guard let output = Self.makeRAWFilter(raw)?.outputImage, output.extent.isInfinite == false else {
        throw SourceImageError.unreadableImage
      }
      self.backing = .raw(raw)
      self.orientation = .up
      self.pixelSize = output.extent.size
    }

    /// The unoriented, full-resolution pixels as a lazy Core Image recipe.
    func makeUnorientedCIImage() -> CIImage {
      switch backing {
      case .imageSource(let imageSource):
        return CIImage(cgImageSource: imageSource, index: 0, options: [:])
      case .bitmap(let cgImage):
        return CIImage(cgImage: cgImage)
      case .raw(let input):
        return Self.makeRAWFilter(input)?.outputImage ?? CIImage.empty()
      }
    }

    /// Unoriented pixels downsampled so that the SHORT side is at most
    /// `shortSideHint`, as the editing source is prepared. See
    /// `ImageTool.makeResizedCGImage(from:maxPixelSizeHint:fixesOrientation:)`.
    func makeResizedCGImage(shortSideHint: CGFloat) -> CGImage? {
      switch backing {
      case .imageSource(let imageSource):
        return ImageTool.makeResizedCGImage(
          from: imageSource,
          maxPixelSizeHint: shortSideHint,
          fixesOrientation: false
        )
      case .bitmap(let cgImage):
        return ImageTool.makeResizedCGImage(from: cgImage, maxPixelSizeHint: shortSideHint)
      case .raw(let input):
        guard let filter = Self.makeRAWFilter(input) else {
          return nil
        }
        let shortSide = min(pixelSize.width, pixelSize.height)
        filter.scaleFactor = Float(min(1, shortSideHint / shortSide))
        guard let output = filter.outputImage else {
          return nil
        }
        return CIContext().createCGImage(output, from: output.extent)
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
      case .raw(let input):
        if let filter = Self.makeRAWFilter(input) {
          filter.scaleFactor = Float(maxPixelSize / max(pixelSize.width, pixelSize.height))
          if let output = filter.outputImage {
            return output
          }
        }
      case .bitmap:
        break
      }
      let scale = maxPixelSize / max(pixelSize.width, pixelSize.height)
      return makeUnorientedCIImage()
        .oriented(orientation)
        .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    private static func makeRAWFilter(_ input: RAWInput) -> CIRAWFilter? {
      switch input {
      case .data(let data):
        return CIRAWFilter(imageData: data, identifierHint: nil)
      case .file(let url):
        return CIRAWFilter(imageURL: url)
      }
    }
  }
}
