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

import Accelerate
import CoreGraphics
import CoreImage
import Metal

import BrightroomEngine
import BrightroomParametric

/// A small rendering of what a canvas shows for a feature, for a histogram and the colour under the
/// pointer.
///
/// `analyze(_:over:adjustmentRendering:)` evaluates the feature through the export path (its
/// effects, the brush blur the canvas composites, the crop the canvas shows and the vignette) over a
/// copy of a preview source, and bins it. Points are in the crop output at full resolution, with a
/// top-left origin: the space in which a macOS canvas reports the pointer.
public struct OutputAnalysis: Sendable {

  /// Counts of each channel's 8-bit display-encoded Display P3 values, 256 bins per channel.
  /// Transparent pixels are left out.
  public struct Histogram: Equatable, Sendable {
    public var red: [UInt32]
    public var green: [UInt32]
    public var blue: [UInt32]
    /// The pixels counted: every pixel that is not transparent.
    public var pixelCount: Int
    /// The largest share of counted pixels at 0 in any channel.
    public var shadowClipping: Double
    /// The largest share of counted pixels at 255 in any channel.
    public var highlightClipping: Double

    public init(
      red: [UInt32],
      green: [UInt32],
      blue: [UInt32],
      pixelCount: Int,
      shadowClipping: Double,
      highlightClipping: Double
    ) {
      self.red = red
      self.green = green
      self.blue = blue
      self.pixelCount = pixelCount
      self.shadowClipping = shadowClipping
      self.highlightClipping = highlightClipping
    }

    /// Each bin divided by the largest bin among 1...254 of all channels, clamped to 1, so that
    /// clipped pixels do not flatten the rest.
    public func levels() -> (red: [Double], green: [Double], blue: [Double]) {
      let peak = [red, green, blue].map { $0.dropFirst().dropLast().max() ?? 0 }.max() ?? 0
      let divisor = Double(max(peak, 1))
      func levels(_ bins: [UInt32]) -> [Double] {
        bins.map { min(1, Double($0) / divisor) }
      }
      return (levels(red), levels(green), levels(blue))
    }
  }

  /// An 8-bit display-encoded Display P3 colour.
  public struct Color: Equatable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
      self.red = red
      self.green = green
      self.blue = blue
    }
  }

  /// The long side of the crop output's copy, at most; never more than the preview's resolution.
  static let maximumPixelSize: CGFloat = 1024

  /// The canvas and export colour contract: an extended-linear Display P3 working space at half
  /// float.
  private static let context: CIContext = {
    let options: [CIContextOption: Any] = [
      .name: "Brightroom.OutputAnalysis",
      .workingColorSpace: EditingCanvasImageProcessing.workingColorSpace,
      .workingFormat: EditingCanvasImageProcessing.workingFormat,
      .cacheIntermediates: false,
    ]
    if let device = MTLCreateSystemDefaultDevice() {
      return CIContext(mtlDevice: device, options: options)
    }
    return CIContext(options: options)
  }()

  public let histogram: Histogram

  /// The full-resolution size of the crop output the bitmap covers: the canvas's content size, and
  /// the space of the points `color(atOutputPoint:)` reads.
  public let outputSize: CGSize

  let pixelWidth: Int
  let pixelHeight: Int

  /// RGBA8 Display P3 with unpremultiplied colours, `pixelWidth` × `pixelHeight`; row 0 is the top
  /// of the picture. A transparent pixel is black.
  let pixels: [UInt8]

  /// The colour at a point of the crop output (full resolution, top-left origin), such as the
  /// pointer a macOS canvas reports; nil outside the output or where it is transparent.
  public func color(atOutputPoint point: CGPoint) -> Color? {
    guard
      point.x >= 0,
      point.y >= 0,
      point.x < outputSize.width,
      point.y < outputSize.height
    else {
      return nil
    }
    let column = min(Int(point.x / outputSize.width * CGFloat(pixelWidth)), pixelWidth - 1)
    let row = min(Int(point.y / outputSize.height * CGFloat(pixelHeight)), pixelHeight - 1)
    let offset = (row * pixelWidth + column) * 4
    guard pixels[offset + 3] > 0 else {
      return nil
    }
    return Color(red: pixels[offset], green: pixels[offset + 1], blue: pixels[offset + 2])
  }

  /// Renders `feature` as a canvas shows it over a copy of `previewSource`, and bins it, off the
  /// calling actor; nil for a degenerate crop or a failed evaluation.
  ///
  /// The copy is at most 1024 pixels on the crop output's long side and never finer than the
  /// preview source, so a tight crop keeps its detail. The crop is fitted to the image as the
  /// canvas fits it, so the analysis covers what the canvas shows.
  ///
  /// When the calling task is already cancelled, such as a `.task(id:)` that a newer feature
  /// replaced, it returns nil without rendering. A rendering that has started runs to its end,
  /// and an analysis of an older feature can end after a newer one's, so check `Task.isCancelled`
  /// before using the result.
  ///
  /// - Parameters:
  ///   - feature: The feature the canvas shows. It is authored over `previewSource.source`; a
  ///     feature of another image is analysed over the wrong pixels.
  ///   - adjustmentRendering: The calculations the adjustments use: the selection the canvas
  ///     renders with (`adjustmentRendering(_:)`).
  @concurrent
  public static func analyze(
    _ feature: ImageEditorFeature,
    over previewSource: PreviewSource,
    adjustmentRendering: AdjustmentRendering = .standard
  ) async -> OutputAnalysis? {
    let preview = previewSource.image
    let imageSize = previewSource.source.pixelSize
    // The canvas fits the crop to the image, so the bitmap is rendered with the canvas's crop:
    // it then covers what the canvas shows, in the coordinates the canvas reports pointers in.
    guard
      let geometry = EditingCanvasCropOutputGeometry(
        crop: CropGuideState(cropFeature: feature.crop, imageSize: imageSize)
      )
    else {
      return nil
    }
    let outputSize = geometry.outputSize

    // The copy's scale follows the crop output rather than the source, so a tight crop keeps its
    // detail, up to the preview's own resolution.
    let previewScale = preview.extent.width / imageSize.width
    let scale = min(previewScale, maximumPixelSize / max(outputSize.width, outputSize.height))
    let source = copy(
      of: preview,
      scaledTo: CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    )

    let output: CIImage
    do {
      output = try feature
        .analysisFeature(cropping: geometry.cropFeature, scaledBy: scale)
        .apply(
          to: source,
          context: FeatureEvaluationContext(
            chainEntryExtent: source.extent,
            renderScale: EditingCanvasRenderImageFactory.renderScale(
              evaluated: source.extent.size,
              fullResolution: imageSize
            ),
            adjustmentRendering: adjustmentRendering
          )
        )
    } catch {
      EditorLog.error(.editingCanvas, "Output analysis failed: \(error)")
      return nil
    }

    guard output.extent.isEmpty == false, output.extent.isInfinite == false else {
      return nil
    }
    // The whole pixels of the crop output, whose origin is zero. Core Image rounds a fractional
    // extent out and draws a partly covered last row (the picture's top) or column translucent, so
    // the bitmap is sized from the output's own size and leaves that row or column out. The
    // tolerance keeps a side that floating-point error leaves just below a whole pixel.
    let width = max(1, Int((outputSize.width * scale + 1e-6).rounded(.down)))
    let height = max(1, Int((outputSize.height * scale + 1e-6).rounded(.down)))
    // The rendering is the expensive part, and once started it runs to its end, so a cancelled
    // caller gets nothing before it starts.
    guard !Task.isCancelled else {
      return nil
    }
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    // Core Image writes the picture's top (its largest y) into row 0, premultiplied.
    context.render(
      output,
      toBitmap: &pixels,
      rowBytes: width * 4,
      bounds: CGRect(x: 0, y: 0, width: width, height: height),
      format: .RGBA8,
      colorSpace: EditingCanvasImageProcessing.drawableColorSpace
    )
    // The colours are unpremultiplied first, so a partly transparent pixel is counted at the colour
    // the readout reports; a transparent pixel stays black. vImage bins by byte position, so an
    // RGBA8 bitmap gives red, green, blue and alpha.
    let (red, green, blue, alpha) = pixels.withUnsafeMutableBytes { bytes in
      var buffer = vImage_Buffer(
        data: bytes.baseAddress!,
        height: vImagePixelCount(height),
        width: vImagePixelCount(width),
        rowBytes: width * 4
      )
      vImageUnpremultiplyData_RGBA8888(&buffer, &buffer, vImage_Flags(kvImageNoFlags))
      return vImage.PixelBuffer(
        data: bytes.baseAddress!,
        width: width,
        height: height,
        byteCountPerRow: width * 4,
        pixelFormat: vImage.Interleaved8x4.self
      )
      .histogram()
    }

    return OutputAnalysis(
      histogram: Histogram(red: red, green: green, blue: blue, alpha: alpha),
      outputSize: outputSize,
      pixelWidth: width,
      pixelHeight: height,
      pixels: pixels
    )
  }

  /// The preview scaled to `size`, each axis on its own as the canvas scales it, so that it covers
  /// the source domain exactly even where the preview's size was rounded; the preview itself when
  /// it has that size. A lazy high-quality resample: Core Image computes only the region the crop
  /// needs.
  private static func copy(of preview: CIImage, scaledTo size: CGSize) -> CIImage {
    let extent = preview.extent
    guard abs(extent.width - size.width) > 1e-6 || abs(extent.height - size.height) > 1e-6 else {
      return preview
    }
    return ImageGeometry.removingExtentOffset(
      preview.transformed(
        by: CGAffineTransform(scaleX: size.width / extent.width, y: size.height / extent.height),
        highQualityDownsample: true
      )
    )
    .cropped(to: CGRect(origin: .zero, size: size))
  }
}

extension OutputAnalysis.Histogram {

  /// The histogram of an RGBA8 unpremultiplied bitmap from the bins of its bytes. A transparent
  /// pixel is black, so the transparent pixels are taken out of bin 0 of each colour.
  fileprivate init(
    red: [vImagePixelCount],
    green: [vImagePixelCount],
    blue: [vImagePixelCount],
    alpha: [vImagePixelCount]
  ) {
    let transparent = alpha[0]
    let pixelCount = Int(alpha.reduce(0, +) - transparent)
    func counted(_ bins: [vImagePixelCount]) -> [UInt32] {
      bins.indices.map { UInt32($0 == 0 ? bins[0] - min(bins[0], transparent) : bins[$0]) }
    }
    let channels = [counted(red), counted(green), counted(blue)]
    func clipping(atBin bin: Int) -> Double {
      guard pixelCount > 0 else {
        return 0
      }
      return Double(channels.map { $0[bin] }.max() ?? 0) / Double(pixelCount)
    }
    self.init(
      red: channels[0],
      green: channels[1],
      blue: channels[2],
      pixelCount: pixelCount,
      shadowClipping: clipping(atBin: 0),
      highlightClipping: clipping(atBin: 255)
    )
  }
}

extension ImageEditorFeature {

  /// This feature over a copy of its source scaled by `scale`: `crop`, scaled, in place of its own
  /// crop, the brush strokes scaled, and the local blur kept only when the canvas composites it.
  ///
  /// Effects and the vignette stay as they are: their radii resolve against the chain entry and the
  /// render scale, and the vignette follows its input.
  fileprivate func analysisFeature(
    cropping crop: CropFeature,
    scaledBy scale: CGFloat
  ) -> ImageEditorFeature {
    let scaling = CGAffineTransform(scaleX: scale, y: scale)
    var feature = self
    feature.crop = crop
    feature.crop.rect = crop.rect.applying(scaling)

    // The canvas composites a brush with strokes only (`CanvasRenderPlan`).
    guard
      case .localBlur(var blur) = CanvasRenderPlan(localBlur: localBlur),
      case .brush(var brush) = blur.mask
    else {
      feature.localBlur = nil
      return feature
    }
    for index in brush.strokes.indices {
      brush.strokes[index].stampCenters = brush.strokes[index].stampCenters.map { $0.applying(scaling) }
      brush.strokes[index].brush.diameter *= scale
    }
    blur.mask = .brush(brush)
    feature.localBlur = blur
    return feature
  }
}
