import CoreImage
import XCTest
import UIKit

@testable import BrightroomEngine
@testable import BrightroomParametric

/// Pins the locked invariant that the interactive preview and the exported
/// result are the *same composition*: `Edit.makePreviewImage(.editing)` (the
/// engine-side preview semantics every UI surface renders) and
/// `BrightRoomImageRenderer` (the export path) must walk the feature list in
/// the same order and produce matching pixels.
///
/// These run at a single resolution (small images, no editing-size downscale)
/// so the comparison isolates the composition contract from resampling.
final class EditingPreviewExportParityTests: XCTestCase {

  private static let context = CIContext()
  private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

  // MARK: - Helpers

  private func export(
    _ edit: EditingStack.Edit,
    source: CGImage
  ) async throws -> CGImage {
    let renderer = BrightRoomImageRenderer(
      source: ImageSource(cgImage: source),
      orientation: .up
    )
    // Build the renderer's parametric document through the production bridge —
    // the same lowering `EditingStack.makeRenderer` uses.
    renderer.edit = .init(
      document: edit.makeEditingDocument(orientedImageSize: edit.imageSize)
    )
    return try await renderer.render(
      options: .init(workingColorSpace: Self.sRGB)
    ).cgImage
  }

  /// The preview composition every UI surface renders, materialized to a
  /// CGImage tagged with the same colorspace the export uses.
  private func previewComposition(
    _ edit: EditingStack.Edit,
    source: CGImage
  ) throws -> CGImage {
    let sourceCIImage = CIImage(cgImage: source)
    let composed = edit.makePreviewImage(from: sourceCIImage, purpose: .editing)
    return try XCTUnwrap(
      Self.context.createCGImage(
        composed,
        from: sourceCIImage.extent,
        format: .RGBA8,
        colorSpace: Self.sRGB
      )
    )
  }

  // MARK: - Parity

  /// Effects + a masked local adjustment with an identity crop: the export and
  /// the preview composition must be pixel-equivalent across the whole frame.
  func testPreviewMatchesExportWithoutCrop() async throws {
    let source = Self.makeSplitImage(
      width: 60,
      height: 24,
      leftWhite: 0.2,
      rightWhite: 0.8
    )
    var edit = EditingStack.Edit.test(imageSize: CGSize(width: 60, height: 24))
    edit.effects = EffectPipeline(effects: [ExposureFeature(value: 0.4)])
    edit.localAdjustments = [
      Self.makeBlurLayer(radius: 8, center: CGPoint(x: 30, y: 12)),
    ]

    let exported = try await export(edit, source: source)
    let preview = try previewComposition(edit, source: source)

    XCTAssertEqual(exported.width, preview.width)
    XCTAssertEqual(exported.height, preview.height)
    // Both paths now rasterize the brush mask through the same parametric
    // `brushStamp` kernel (preview via `engineMakeMaskImage`, export via the
    // compiler), so they agree closely; the small tolerance only absorbs
    // resampling/rounding at the blur-gradient edge. A real composition bug
    // (wrong order, missing/unmasked adjustment, a y-flip) still diverges by
    // tens-to-hundreds of LSB, far beyond this tolerance.
    assertImagesMatch(exported, preview, tolerance: 16)
  }

  /// A non-identity crop (no rotation): export pixel (x, y) must equal the
  /// preview composition at (cropMinX + x, cropMinY + y), proving both paths
  /// apply the crop to the same composed image.
  func testPreviewMatchesExportThroughCrop() async throws {
    let source = Self.makeSplitImage(
      width: 60,
      height: 24,
      leftWhite: 0.2,
      rightWhite: 0.8
    )
    let cropRect = CGRect(x: 30, y: 0, width: 30, height: 24)
    var edit = EditingStack.Edit.test(imageSize: CGSize(width: 60, height: 24))
    edit.crop = CropFeature.test(
      imageSize: CGSize(width: 60, height: 24),
      cropRect: cropRect
    )
    edit.effects = EffectPipeline(effects: [ExposureFeature(value: 0.4)])
    edit.localAdjustments = [
      Self.makeBlurLayer(radius: 8, center: CGPoint(x: 30, y: 12)),
    ]

    let exported = try await export(edit, source: source)
    let preview = try previewComposition(edit, source: source)

    XCTAssertEqual(exported.width, Int(cropRect.width))
    XCTAssertEqual(exported.height, Int(cropRect.height))

    for (x, y) in [(2, 12), (14, 6), (27, 18)] {
      let exportedPixel = Self.rgba(in: exported, x: x, y: y)
      let previewPixel = Self.rgba(
        in: preview,
        x: x + Int(cropRect.minX),
        y: y + Int(cropRect.minY)
      )
      assertPixelsMatch(exportedPixel, previewPixel, tolerance: 4, label: "(\(x),\(y))")
    }
  }

  /// A disabled brush leaf must select nothing in BOTH paths: export and
  /// preview equal the globally-adjusted image with no local blur, matching the
  /// parametric compiler's transparent disabled-leaf contract.
  func testDisabledMaskLeafIsIgnoredByBothPaths() async throws {
    let source = Self.makeSplitImage(
      width: 60,
      height: 24,
      leftWhite: 0.2,
      rightWhite: 0.8
    )
    let baseImageSize = CGSize(width: 60, height: 24)

    var disabledEdit = EditingStack.Edit.test(imageSize: baseImageSize)
    disabledEdit.effects = EffectPipeline(effects: [ExposureFeature(value: 0.4)])
    var disabledLayer = Self.makeBlurLayer(radius: 8, center: CGPoint(x: 30, y: 12))
    if case var .brush(mask) = disabledLayer.maskTree.root {
      mask.isEnabled = false
      disabledLayer.maskTree.root = .brush(mask)
    }
    disabledEdit.localAdjustments = [disabledLayer]

    // Reference: same document with no local adjustment at all.
    var globalOnlyEdit = EditingStack.Edit.test(imageSize: baseImageSize)
    globalOnlyEdit.effects = EffectPipeline(effects: [ExposureFeature(value: 0.4)])

    let disabledExport = try await export(disabledEdit, source: source)
    let globalOnlyExport = try await export(globalOnlyEdit, source: source)
    let disabledPreview = try previewComposition(disabledEdit, source: source)

    // The disabled-leaf export must equal the no-adjustment export...
    assertImagesMatch(disabledExport, globalOnlyExport, tolerance: 2)
    // ...and the preview must match the export (same disabled-leaf semantics).
    assertImagesMatch(disabledPreview, disabledExport, tolerance: 4)
  }

  /// A local-adjustment effect that throws must fail the export, surfaced like
  /// a throwing global effect instead of silently exporting an image missing
  /// the adjustment.
  ///
  /// (The preview path's release-mode degrade-to-identity is not asserted here:
  /// `engineRenderIgnoringFailure` calls `assertionFailure`, which traps in the
  /// debug test build — the same intentional contract global effects use.)
  func testThrowingLocalAdjustmentFailsExport() async throws {
    let source = Self.makeSolidImage(width: 32, height: 32, white: 0.5)
    var edit = EditingStack.Edit.test(imageSize: CGSize(width: 32, height: 32))

    let throwingLayer = LocalAdjustmentFeature(
      maskTree: MaskTree(
        root: .brush(
          BrushMask(strokes: [
            BrushMaskStroke(
              stamps: [CGPoint(x: 16, y: 16)],
              brush: BrushMaskBrush(diameter: 12, hardness: 1, opacity: 1)
            )
          ])
        )
      ),
      effectPipeline: EffectPipeline(effects: [ThrowingEffectFeature()])
    )
    edit.localAdjustments = [throwingLayer]

    do {
      _ = try await export(edit, source: source)
      XCTFail("expected export to throw")
    } catch {
      XCTAssertTrue(error is ThrowingEffectFeature.EvaluationError)
    }
  }

  /// The shared parametric `brushStamp` kernel (used by the engine preview and
  /// the export renderer via `engineMakeMaskImage` / `renderMask`) must produce
  /// the falloff `(1 - smoothstep(hardness, 1, d)) * opacity` the live canvas
  /// shader also draws. If it used a hard disc or a linear ramp, painted blur
  /// edges would render wider/harder than the interactive preview showed. This
  /// samples the alpha profile of a single soft stamp and checks that contract.
  func testExportMaskReproducesLiveCanvasBrushFalloff() throws {
    let canvas = 300
    let center = CGPoint(x: 150, y: 150)
    let diameter = 200.0
    let radius = diameter / 2
    let hardness = 0.5

    let tree = MaskTree(root: .brush(BrushMask(strokes: [
      BrushMaskStroke(
        stamps: [center],
        brush: BrushMaskBrush(diameter: diameter, hardness: hardness, opacity: 1)
      )
    ])))
    let maskCIImage = try XCTUnwrap(
      tree.engineMakeMaskImage(size: CGSize(width: canvas, height: canvas))
    )
    let maskCG = try XCTUnwrap(
      Self.context.createCGImage(maskCIImage, from: CGRect(x: 0, y: 0, width: canvas, height: canvas))
    )

    func alpha(atNormalizedRadius t: Double) -> Double {
      let x = Int((center.x + CGFloat(t) * radius).rounded())
      return Double(Self.rgba(in: maskCG, x: x, y: Int(center.y)).alpha) / 255
    }

    func smoothstepFalloff(_ t: Double) -> Double {
      if t <= hardness { return 1 }
      if t >= 1 { return 0 }
      let u = (t - hardness) / (1 - hardness)
      return 1 - (3 * u * u - 2 * u * u * u)
    }

    // Core is fully covered, edge is clear, falloff is monotonic, and the
    // midpoint matches the smoothstep value (a hard disc would read ~1.0 there).
    XCTAssertGreaterThan(alpha(atNormalizedRadius: 0.2), 0.95)
    XCTAssertGreaterThan(alpha(atNormalizedRadius: hardness - 0.05), 0.95)
    XCTAssertLessThan(alpha(atNormalizedRadius: 1.1), 0.05)

    var previous = 1.1
    for t in stride(from: 0.55, through: 1.0, by: 0.05) {
      let a = alpha(atNormalizedRadius: t)
      XCTAssertLessThanOrEqual(a, previous + 0.02, "falloff not monotonic at t=\(t)")
      previous = a
      XCTAssertEqual(
        a, smoothstepFalloff(t), accuracy: 0.08,
        "export falloff at t=\(t) (\(a)) deviates from the live brush smoothstep (\(smoothstepFalloff(t)))"
      )
    }
  }

  // MARK: - Assertions

  private func assertImagesMatch(
    _ lhs: CGImage,
    _ rhs: CGImage,
    tolerance: Int,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(lhs.width, rhs.width, "width", file: file, line: line)
    XCTAssertEqual(lhs.height, rhs.height, "height", file: file, line: line)
    let step = max(1, lhs.width / 12)
    for x in stride(from: 0, to: lhs.width, by: step) {
      for y in stride(from: 0, to: lhs.height, by: max(1, lhs.height / 6)) {
        assertPixelsMatch(
          Self.rgba(in: lhs, x: x, y: y),
          Self.rgba(in: rhs, x: x, y: y),
          tolerance: tolerance,
          label: "(\(x),\(y))",
          file: file,
          line: line
        )
      }
    }
  }

  private func assertPixelsMatch(
    _ lhs: RGBA,
    _ rhs: RGBA,
    tolerance: Int,
    label: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    func diff(_ a: UInt8, _ b: UInt8) -> Int { abs(Int(a) - Int(b)) }
    let r = diff(lhs.red, rhs.red)
    let g = diff(lhs.green, rhs.green)
    let b = diff(lhs.blue, rhs.blue)
    XCTAssertLessThanOrEqual(
      max(r, g, b),
      tolerance,
      "pixel \(label) diverged: export \(lhs) vs preview \(rhs)",
      file: file,
      line: line
    )
  }

  // MARK: - Fixtures

  private static func makeBlurLayer(
    radius: CGFloat,
    center: CGPoint
  ) -> LocalAdjustmentFeature {
    .init(
      maskTree: MaskTree(
        root: .brush(
          BrushMask(strokes: [
            BrushMaskStroke(
              stamps: [center],
              brush: BrushMaskBrush(diameter: 18, hardness: 1, opacity: 1)
            )
          ])
        )
      ),
      effectPipeline: EffectPipeline(effects: [GaussianBlurFeature(radius: Double(radius))])
    )
  }

  private static func makeSplitImage(
    width: Int,
    height: Int,
    leftWhite: CGFloat,
    rightWhite: CGFloat
  ) -> CGImage {
    let size = CGSize(width: width, height: height)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
      UIColor(white: leftWhite, alpha: 1).setFill()
      UIRectFill(CGRect(origin: .zero, size: size))
      UIColor(white: rightWhite, alpha: 1).setFill()
      UIRectFill(CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height))
    }.cgImage!
  }

  private static func makeSolidImage(
    width: Int,
    height: Int,
    white: CGFloat
  ) -> CGImage {
    let size = CGSize(width: width, height: height)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
      UIColor(white: white, alpha: 1).setFill()
      UIRectFill(CGRect(origin: .zero, size: size))
    }.cgImage!
  }

  private static func rgba(in image: CGImage, x: Int, y: Int) -> RGBA {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
      data: &pixels,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let clampedX = min(max(x, 0), width - 1)
    let clampedY = min(max(y, 0), height - 1)
    let offset = (clampedY * width + clampedX) * 4
    return RGBA(
      red: pixels[offset],
      green: pixels[offset + 1],
      blue: pixels[offset + 2],
      alpha: pixels[offset + 3]
    )
  }

  private struct RGBA: Equatable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
    var alpha: UInt8
  }
}

/// A local-adjustment effect that always throws, to prove the export path
/// surfaces evaluation failures instead of silently dropping the adjustment.
private struct ThrowingEffectFeature: ImageEffectFeatureType {
  struct EvaluationError: Error {}

  var id: FeatureID = .init(rawValue: "test.throwing-effect")
  var isEnabled: Bool = true

  func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    throw EvaluationError()
  }
}
