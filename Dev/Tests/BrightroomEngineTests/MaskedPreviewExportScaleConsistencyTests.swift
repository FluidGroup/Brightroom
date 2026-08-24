import CoreImage
import Foundation
import Testing
import UIKit

@testable import BrightroomEngine
@testable import BrightroomParametric
@testable import BrightroomUI

/// Guards the "preview matches export" contract for the local-adjustment blur
/// after the large-image OOM fix.
///
/// `EditingCanvasRenderImageFactory` evaluates the local-adjustment blur at the
/// **downsampled editing-source resolution** and upscales the result, rather
/// than blurring the full-canvas (`canvasSize`) image — which OOM-crashes on
/// very large sources (e.g. the 12000×12000 "Nasa" image). The full-resolution
/// export blurs the full-size source directly.
///
/// Those two evaluations land on the same visual result *because the blur radius
/// is a fraction of the image extent* (`radiusReferenceExtent == nil` →
/// `image.extent`): a fraction of 256 upscaled 4× equals the same fraction of
/// 1024. This test renders both and asserts they agree within a loose tolerance
/// — "loose" because the preview starts from a downsampled source, so a small
/// resampling discrepancy is expected and acceptable (the same kind of
/// preview/export drift any editor has).
struct MaskedPreviewExportScaleConsistencyTests {

  /// Downsampled editing-source side (stands in for the ~2560 editing source).
  private static let sourceSide = 256
  /// Full-resolution side (stands in for the original image / export size).
  private static let fullSide = 1024

  private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

  @Test func `Source resolution blur preview matches full resolution export`() throws {
    let fullSize = CGSize(width: Self.fullSide, height: Self.fullSide)

    // A hard vertical edge: left half black, right half white. The edge is
    // symmetric top-to-bottom, so the factory's display y-flip is invisible and
    // the only signal is the horizontal blur ramp — whose width is set by the
    // (fractional) blur radius.
    let sourceEdgeCG = Self.makeVerticalEdge(side: Self.sourceSide)
    let fullEdgeCI = CIImage(cgImage: Self.makeVerticalEdge(side: Self.fullSide))

    // A Loaded whose editing source is the SMALL edge but whose image size is
    // the FULL side, so the factory must upscale source→canvas (the Nasa shape:
    // small editing source, large canvas).
    let edit = EditingStack.Edit.test(imageSize: fullSize)
    let sourceEdgeCI = CIImage(cgImage: sourceEdgeCG)
    let loaded = EditingStack.Loaded(
      imageSource: ImageSource(cgImage: sourceEdgeCG),
      metadata: .init(orientation: .up, imageSize: fullSize),
      initialEditing: edit,
      currentEdit: edit,
      thumbnailCIImage: sourceEdgeCI,
      editingSourceCGImage: sourceEdgeCG,
      editingSourceCIImage: sourceEdgeCI
    )

    let blur = EffectPipeline(effects: [GaussianBlurFeature(value: 40)])

    // PREVIEW: the factory's local-adjustment `adjusted` layer is the blur
    // applied to the whole image (the mask selects it later in compositing), so
    // it is directly comparable to a global blur. With the OOM fix this is
    // computed at the 256 source and upscaled to 1024.
    let previewImages = try #require(
      EditingCanvasRenderImageFactory.makeRenderImages(
        loadedState: loaded,
        canvasSize: fullSize,
        mode: .localAdjustment(effect: blur)
      )
    )
    let previewRow = try centerRow(of: previewImages.adjusted, side: Self.fullSide)

    // EXPORT reference: the same blur applied to the FULL-resolution source,
    // exactly as the export renderer does (radiusReferenceExtent nil → relative
    // to the full extent).
    let exportImage = blur.applyIgnoringFailure(to: fullEdgeCI)
    let exportRow = try centerRow(of: exportImage, side: Self.fullSide)

    // Sanity: both are dark on the left and bright on the right (the blur did
    // not destroy the edge, and orientation matches).
    #expect(Int(previewRow[Self.fullSide / 8]) < 64, "preview left should be dark")
    #expect(Int(previewRow[Self.fullSide * 7 / 8]) > 191, "preview right should be bright")
    #expect(Int(exportRow[Self.fullSide / 8]) < 64, "export left should be dark")
    #expect(Int(exportRow[Self.fullSide * 7 / 8]) > 191, "export right should be bright")

    // (1) Holistic agreement: the whole blurred profile must match on average.
    // A divergent blur *fraction* would smear a large difference across the
    // entire transition band and spike this; observed ≈ 0.1/255. (A single
    // near-vertical column at the exact edge can differ by a sub-pixel
    // registration step between the downsampled-then-upscaled source and the
    // native source — that is the inherent, accepted preview/export drift — so
    // mean, not per-column max, is the meaningful holistic metric.)
    var total = 0.0
    for x in 0..<Self.fullSide {
      total += Double(abs(Int(previewRow[x]) - Int(exportRow[x])))
    }
    let meanDiff = total / Double(Self.fullSide)
    #expect(
      meanDiff < 6,
      "Source-resolution blur preview should match full-resolution export on average (mean diff \(meanDiff))"
    )

    // (2) Blur AMOUNT: the 25%→75% rise width is set purely by the blur radius
    // and is invariant to sub-pixel translation. A wrong radius scaling between
    // the two paths (the real regression this fix guards against) would change
    // it; sub-pixel edge phase will not.
    let previewWidth = Self.riseWidth(previewRow)
    let exportWidth = Self.riseWidth(exportRow)
    #expect(
      abs(Double(previewWidth) - Double(exportWidth)) <= max(4, Double(exportWidth) * 0.15),
      "Blur ramp width (∝ radius) must match between source-res preview and full-res export (preview \(previewWidth)px, export \(exportWidth)px)"
    )
  }

  /// Nasa-scale guard for the OOM fix: with a ~256 editing source and a
  /// 12000×12000 canvas (the "Nasa" shape), rendering the local-adjustment
  /// `adjusted` layer must stay bounded. We ask Core Image for only a small
  /// region of the 12000²-extent adjusted image. With the fix, the blur's INPUT
  /// is the ~256 source (CIGaussianBlur rasterizes its input at the input grid),
  /// and the upscale/crop after it are lazy affines that CI evaluates at the
  /// requested-region rate — so the ROI for a 512² region stays a tiny patch of
  /// the 256 source. (The pre-fix code blurred the 12000²-upscaled image, which
  /// forced a 12000² blur-input buffer → the EXC_RESOURCE OOM.)
  ///
  /// This also pins the upscale coordinate mapping: the source edge at x=128/256
  /// must land at x=6000/12000 in the rendered region.
  ///
  /// NOTE: this exercises the lazy render chain at Nasa scale; the *definitive*
  /// memory confirmation is a manual paint on the real 12000² image (a device
  /// memory-watermark crash cannot be asserted in a unit test).
  @Test func `Nasa scale local adjustment renders bounded region`() throws {
    let canvasSide = 12000
    let canvasSize = CGSize(width: canvasSide, height: canvasSide)

    let sourceEdgeCG = Self.makeVerticalEdge(side: Self.sourceSide)
    let sourceEdgeCI = CIImage(cgImage: sourceEdgeCG)
    let edit = EditingStack.Edit.test(imageSize: canvasSize)
    let loaded = EditingStack.Loaded(
      imageSource: ImageSource(cgImage: sourceEdgeCG),
      metadata: .init(orientation: .up, imageSize: canvasSize),
      initialEditing: edit,
      currentEdit: edit,
      thumbnailCIImage: sourceEdgeCI,
      editingSourceCGImage: sourceEdgeCG,
      editingSourceCIImage: sourceEdgeCI
    )

    let blur = EffectPipeline(effects: [GaussianBlurFeature(value: 40)])
    // The factory renders the FULL 12000² canvas (the not-zoomed case that
    // crashed): the adjusted image carries a 12000² extent.
    let images = try #require(
      EditingCanvasRenderImageFactory.makeRenderImages(
        loadedState: loaded,
        canvasSize: canvasSize,
        mode: .localAdjustment(effect: blur)
      )
    )
    #expect(abs(images.adjusted.extent.width - CGFloat(canvasSide)) <= 1)

    // Render a full-width, 4px-tall strip at the vertical center. The OUTPUT is
    // tiny (12000×4 ≈ 192KB) and the ROI maps back to the ~256-wide source (the
    // blur evaluates at source scale), so this stays bounded — a regression to
    // blurring the 12000²-upscaled image would instead force a ~12000²
    // blur-input buffer. That this render succeeds at all is the boundedness
    // signal; the values then pin the upscale coordinate mapping.
    let strip = CGRect(x: 0, y: CGFloat(canvasSide) / 2 - 2, width: CGFloat(canvasSide), height: 4)
    let cg = try #require(
      ciContext.createCGImage(
        images.adjusted,
        from: strip,
        format: .RGBA8,
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
      ),
      "Rendering a full-width strip of the Nasa-scale adjusted image must succeed"
    )
    #expect(cg.width == canvasSide)

    let row = try centerRow(ofCG: cg)
    // Far from the edge the blur has fully settled: black on the left, white on
    // the right. (Sample well clear of the wide blur ramp.)
    #expect(Int(row[200]) < 32, "far left of the Nasa-scale edge should be black")
    #expect(Int(row[canvasSide - 200]) > 223, "far right of the Nasa-scale edge should be white")

    // The source edge at x=128/256 must land at x=6000/12000 (×46.875 upscale).
    // The blur is symmetric, so the 50%-brightness crossing stays on the edge.
    let crossing = row.firstIndex { $0 >= 128 } ?? -1
    #expect(
      abs(Double(crossing) - 6000) <= 300,
      "Upscaled edge crossing should land at x≈6000 (got \(crossing))"
    )
  }

  // MARK: - Fixtures

  /// The horizontal distance (px) over which a left-dark→right-bright row rises
  /// from 25% (64) to 75% (191) brightness. Proportional to the blur radius and
  /// invariant to sub-pixel translation, so it isolates "how much blur" from
  /// "where exactly the edge sits".
  private static func riseWidth(_ row: [UInt8]) -> Int {
    let low = row.firstIndex { $0 >= 64 } ?? 0
    let high = row.firstIndex { $0 >= 191 } ?? (row.count - 1)
    return max(0, high - low)
  }

  /// Reads the horizontal center row's red channel from a `CIImage` rendered to
  /// a `side`×`side` bitmap.
  private func centerRow(of image: CIImage, side: Int) throws -> [UInt8] {
    let cg = try #require(
      ciContext.createCGImage(
        image,
        from: CGRect(x: 0, y: 0, width: side, height: side),
        format: .RGBA8,
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
      )
    )
    return try centerRow(ofCG: cg)
  }

  /// Reads the horizontal center row's red channel from an already-rendered
  /// `CGImage`.
  private func centerRow(ofCG cg: CGImage) throws -> [UInt8] {
    let width = cg.width
    let height = cg.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(
      data: &pixels,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue
    )!
    context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

    let y = height / 2
    var row = [UInt8](repeating: 0, count: width)
    for x in 0..<width {
      row[x] = pixels[(y * width + x) * 4]
    }
    return row
  }

  private static func makeVerticalEdge(side: Int) -> CGImage {
    let size = CGSize(width: side, height: side)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
      UIColor.black.setFill()
      UIRectFill(CGRect(x: 0, y: 0, width: side, height: side))
      UIColor.white.setFill()
      UIRectFill(CGRect(x: side / 2, y: 0, width: side - side / 2, height: side))
    }.cgImage!
  }
}
