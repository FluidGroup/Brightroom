//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
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
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encodes a (potentially very large) `CIImage` to a file with **bounded peak
/// memory**, instead of the ~`W·H·4`-byte spike that
/// `CIContext.write{JPEG,HEIF}Representation` / `createCGImage(from: fullExtent)`
/// incur (they materialize the whole bitmap in RAM before encoding).
///
/// Strategy (system frameworks only, no third-party encoder):
/// 1. Back the full-resolution bitmap with a memory-mapped **temp file** sized
///    `W·H·4`. The bytes live on DISK; dirty pages flush under memory pressure,
///    so they are not pinned in RAM.
/// 2. Render the `CIImage` into that buffer **one horizontal strip at a time**
///    via `CIContext.render(_:toBitmap:rowBytes:bounds:format:colorSpace:)`.
///    `bounds` selects only the strip's source region, and Core Image pulls the
///    exact input ROI it needs (including a blur's halo across strip edges), so
///    the per-strip render working set is ≈ one strip + halo — not the whole
///    image.
/// 3. Wrap the mmap'd buffer in a `CGImage` whose pixels are supplied lazily by
///    a direct `CGDataProvider`. `CGImageDestination` then demand-pages through
///    the provider during encode, so the encoder never forces the whole bitmap
///    resident either (proven pattern; see dhoerl/PhotoScroller).
///
/// Peak RAM ≈ one strip + Core Image render scratch + the encoder's working set,
/// while the full-resolution bytes stay on disk. The scratch file is removed
/// when the backing `CGImage`/provider is released (after `Finalize`).
///
/// - Note: The encode step's exact paging behavior is not Apple-documented;
///   confirm the win on-device with Instruments (Allocations / VM Tracker).
/// - Note: Output is opaque-correct. Pixels are rendered as `kCIFormatRGBA8` and
///   tagged premultiplied-last; Brightroom's export is opaque (alpha == 1), so
///   premultiplied vs. straight alpha is moot here.
enum CIImageStreamingFileWriter {

  enum WriterError: Swift.Error {
    case invalidExtent
    case scratchCreationFailed
    case mmapFailed
    case providerCreationFailed
    case cgImageCreationFailed
    case destinationCreationFailed
    case finalizeFailed
  }

  /// Output rows rendered per `render(_:toBitmap:bounds:)` call. Bounds the
  /// per-strip working set; smaller = lower peak (more, smaller GPU readbacks).
  static let defaultStripHeight = 512

  static func write(
    _ image: CIImage,
    to url: URL,
    fileType: ParametricExportRenderer.ExportFileType,
    context: CIContext,
    colorSpace: CGColorSpace,
    stripHeight: Int = defaultStripHeight
  ) throws {
    let extent = image.extent
    guard
      extent.isNull == false,
      extent.isInfinite == false,
      extent.width >= 1,
      extent.height >= 1
    else {
      throw WriterError.invalidExtent
    }

    let width = Int(extent.width.rounded())
    let height = Int(extent.height.rounded())
    let bytesPerPixel = 4
    let rowBytes = width * bytesPerPixel
    let totalBytes = rowBytes * height

    // 1. Disk-backed scratch buffer (sparse file, mmap'd).
    let scratchURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("brightroom-export-scratch-\(UUID().uuidString).raw")

    let fd = open(scratchURL.path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
    guard fd >= 0 else {
      throw WriterError.scratchCreationFailed
    }
    guard ftruncate(fd, off_t(totalBytes)) == 0 else {
      close(fd)
      try? FileManager.default.removeItem(at: scratchURL)
      throw WriterError.scratchCreationFailed
    }
    let mapped = mmap(nil, totalBytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
    guard let base = mapped, base != MAP_FAILED else {
      close(fd)
      try? FileManager.default.removeItem(at: scratchURL)
      throw WriterError.mmapFailed
    }

    // 2. Render strip-by-strip into the mmap'd buffer.
    //
    // The destination buffer is top-left origin (row 0 = top), but CIImage is
    // y-up (origin bottom-left). Display rows [top, top+h) map to the y-up band
    // [maxY - top - h, maxY - top]; `render(_:toBitmap:bounds:)` writes that
    // band top-first into `dst`, so placing it at row offset `top` keeps the
    // output oriented exactly like `createCGImage`.
    let minX = extent.minX
    let maxY = extent.maxY
    var top = 0
    while top < height {
      let h = min(stripHeight, height - top)
      let bounds = CGRect(
        x: minX,
        y: maxY - CGFloat(top) - CGFloat(h),
        width: CGFloat(width),
        height: CGFloat(h)
      )
      context.render(
        image,
        toBitmap: base.advanced(by: top * rowBytes),
        rowBytes: rowBytes,
        bounds: bounds,
        format: .RGBA8,
        colorSpace: colorSpace
      )
      top += h
    }

    // 3. Lazy CGImage over the mmap'd buffer. From here the `scratch` owns the
    //    unmap/close/unlink, run from the provider's release callback — so once
    //    the provider (hence CGImage, hence destination) is gone, cleanup runs.
    let scratch = MmapScratch(url: scratchURL, fd: fd, base: base, size: totalBytes)
    let info = Unmanaged.passRetained(scratch).toOpaque()
    var callbacks = CGDataProviderDirectCallbacks(
      version: 0,
      getBytePointer: { info in
        UnsafeRawPointer(Unmanaged<MmapScratch>.fromOpaque(info!).takeUnretainedValue().base)
      },
      releaseBytePointer: nil,
      getBytesAtPosition: nil,
      releaseInfo: { info in
        Unmanaged<MmapScratch>.fromOpaque(info!).takeRetainedValue().cleanup()
      }
    )
    guard let provider = CGDataProvider(directInfo: info, size: off_t(totalBytes), callbacks: &callbacks) else {
      Unmanaged<MmapScratch>.fromOpaque(info).release()
      scratch.cleanup()
      throw WriterError.providerCreationFailed
    }
    // `provider` now owns `scratch` cleanup via `releaseInfo`.

    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
      | CGBitmapInfo.byteOrder32Big.rawValue
    guard let cgImage = CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: rowBytes,
      space: colorSpace,
      bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    ) else {
      throw WriterError.cgImageCreationFailed
    }

    // 4. Encode. CGImageDestination demand-pages pixels through the provider.
    let utType: UTType
    var options: [CFString: Any] = [:]
    switch fileType {
    case .jpeg(let quality):
      utType = .jpeg
      options[kCGImageDestinationLossyCompressionQuality] = quality
    case .heif(let quality):
      utType = .heic
      options[kCGImageDestinationLossyCompressionQuality] = quality
    case .png:
      utType = .png
    }

    guard
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        utType.identifier as CFString,
        1,
        nil
      )
    else {
      throw WriterError.destinationCreationFailed
    }
    CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      throw WriterError.finalizeFailed
    }
    // `cgImage` / `provider` drop here → `scratch.cleanup()` removes the temp file.
    withExtendedLifetime(cgImage) {}
  }

  /// Owns the lifetime of the mmap'd scratch file; `cleanup` is driven by the
  /// `CGDataProvider`'s release callback.
  private final class MmapScratch {
    let url: URL
    let fd: Int32
    let base: UnsafeMutableRawPointer
    let size: Int

    init(url: URL, fd: Int32, base: UnsafeMutableRawPointer, size: Int) {
      self.url = url
      self.fd = fd
      self.base = base
      self.size = size
    }

    func cleanup() {
      munmap(base, size)
      close(fd)
      try? FileManager.default.removeItem(at: url)
    }
  }
}
