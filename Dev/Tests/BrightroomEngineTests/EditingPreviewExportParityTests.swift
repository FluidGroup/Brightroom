import CoreImage
import Foundation
import Metal
import Testing
import UIKit

@testable import BrightroomEngine
@testable import BrightroomParametric
@testable import BrightroomUI

/// Pins the locked invariant that the interactive preview and the exported
/// result are the *same composition*: the canvas composition `EditingCanvasView`
/// renders for an `ImageEditorFeature` (`CanvasCompositionPreview`) and the
/// export of the same feature through `EditingDocument.render(options:)`
/// must produce matching pixels.
///
/// These run at a single resolution (small images, the editing source is the
/// full-resolution image) so the comparison isolates the composition contract
/// from resampling.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct EditingPreviewExportParityTests {

  private static let context = CIContext()
  private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

  // MARK: - Helpers

  private func export(
    _ document: some Feature & Equatable,
    source: CGImage
  ) async throws -> CGImage {
    try await EditingDocument(source: SourceImage(cgImage: source), feature: document).render(
      options: .init(outputColorSpace: Self.sRGB)
    ).cgImage
  }

  // MARK: - Parity

  /// Effects + a masked blur with an identity crop: the export and the canvas
  /// composition must be pixel-equivalent across the whole frame.
  @Test func `Preview matches export without crop`() async throws {
    let imageSize = CGSize(width: 60, height: 24)
    let source = Self.makeSplitImage(
      width: 60,
      height: 24,
      leftWhite: 0.2,
      rightWhite: 0.8
    )
    let document = Self.makeDocument(
      imageSize: imageSize,
      localBlur: Self.makeLocalBlur(
        radius: 8,
        displayCenter: CGPoint(x: 30, y: 12),
        domainHeight: imageSize.height
      )
    )

    let exported = try await export(document, source: source)
    let preview = try CanvasCompositionPreview.render(document: document, source: source)

    #expect(exported.width == preview.width)
    #expect(exported.height == preview.height)
    // The canvas rasterizes the brush with the Metal stamp shader and export
    // with the parametric kernel, which share one falloff; the small tolerance
    // only absorbs resampling/rounding at the blur-gradient edge. A real
    // composition bug (wrong order, missing/unmasked adjustment, a y-flip)
    // still diverges by tens-to-hundreds of LSB, far beyond this tolerance.
    assertImagesMatch(exported, preview, tolerance: 16)
  }

  /// An off-center stamp: the blur lands at the painted display position in
  /// both paths, and not at its vertical mirror.
  @Test func `Preview and export agree on the painted position`() async throws {
    let imageSize = CGSize(width: 60, height: 40)
    let source = Self.makeCheckerImage(width: 60, height: 40, cell: 2)
    let painted = CGPoint(x: 20, y: 8)
    let mirrored = CGPoint(x: 20, y: imageSize.height - 8)
    let document = Self.makeDocument(
      imageSize: imageSize,
      localBlur: Self.makeLocalBlur(radius: 4, displayCenter: painted, domainHeight: imageSize.height)
    )
    var unmasked = document
    unmasked.localBlur = nil

    let exported = try await export(document, source: source)
    let preview = try CanvasCompositionPreview.render(document: document, source: source)
    let reference = try await export(unmasked, source: source)

    func delta(_ image: CGImage, _ point: CGPoint) -> Int {
      let a = Self.rgba(in: image, x: Int(point.x), y: Int(point.y))
      let b = Self.rgba(in: reference, x: Int(point.x), y: Int(point.y))
      return abs(Int(a.red) - Int(b.red))
    }

    #expect(delta(exported, painted) > 20, "export: blur missing at the painted position")
    #expect(delta(preview, painted) > 20, "preview: blur missing at the painted position")
    #expect(delta(exported, mirrored) <= 2, "export: blur leaked to the mirrored position")
    #expect(delta(preview, mirrored) <= 2, "preview: blur leaked to the mirrored position")
  }

  /// A non-identity crop (no rotation): export pixel (x, y) must equal the
  /// source-domain canvas composition at (cropMinX + x, cropMinY + y), proving
  /// both paths apply the crop to the same composed image.
  @Test func `Preview matches export through crop`() async throws {
    let imageSize = CGSize(width: 60, height: 24)
    let source = Self.makeSplitImage(
      width: 60,
      height: 24,
      leftWhite: 0.2,
      rightWhite: 0.8
    )
    let cropRect = CGRect(x: 30, y: 0, width: 30, height: 24)
    let document = Self.makeDocument(
      imageSize: imageSize,
      cropRect: cropRect,
      localBlur: Self.makeLocalBlur(
        radius: 8,
        displayCenter: CGPoint(x: 30, y: 12),
        domainHeight: imageSize.height
      )
    )

    let exported = try await export(document, source: source)
    let preview = try CanvasCompositionPreview.render(document: document, source: source)

    #expect(exported.width == Int(cropRect.width))
    #expect(exported.height == Int(cropRect.height))

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

  /// A rotated crop: the tool surface's crop-output composition matches the
  /// export of the same document pixel for pixel (up to tolerance), including
  /// where the off-center stamp lands after the rotation.
  @Test func `Crop output preview matches export through a rotated crop`() async throws {
    let imageSize = CGSize(width: 60, height: 40)
    // Asymmetric in both axes, so a missing or wrong-signed rotation on either
    // side changes the compared pixels.
    let source = Self.makeRampedCheckerImage(width: 60, height: 40, cell: 2)
    let document = Self.makeDocument(
      imageSize: imageSize,
      cropRect: CGRect(x: 10, y: 4, width: 40, height: 30),
      rotation: .counterclockwise90,
      localBlur: Self.makeLocalBlur(
        radius: 4,
        displayCenter: CGPoint(x: 20, y: 10),
        domainHeight: imageSize.height
      )
    )

    let exported = try await export(document, source: source)
    let preview = try CanvasCompositionPreview.render(
      document: document,
      source: source,
      throughCrop: true
    )

    // The crop rect is the selection before the output quarter turn, so the
    // sideways turn exchanges the output's width and height.
    #expect(document.crop.quarterTurn != .zero)
    #expect(exported.width == 30)
    #expect(exported.height == 40)
    assertImagesMatch(exported, preview, tolerance: 16)

    // The rotation is visible in the compared pixels: without it the export
    // differs, so the match above cannot come from an ignored rotation.
    let unrotated = try await export(
      Self.makeDocument(
        imageSize: imageSize,
        cropRect: CGRect(x: 10, y: 4, width: 40, height: 30),
        localBlur: document.localBlur
      ),
      source: source
    )
    let largestDifference = [(4, 4), (20, 8), (25, 15), (8, 26)]
      .map { x, y in
        abs(Int(Self.rgba(in: exported, x: x, y: y).red) - Int(Self.rgba(in: unrotated, x: x, y: y).red))
      }
      .max() ?? 0
    #expect(largestDifference > 40)
  }

  /// A brush with no strokes must select nothing in BOTH paths: export and
  /// preview equal the globally-adjusted image with no local blur, matching the
  /// mask renderer's transparent empty-brush contract.
  @Test func `An empty brush mask is ignored by both paths`() async throws {
    let imageSize = CGSize(width: 60, height: 24)
    let source = Self.makeSplitImage(
      width: 60,
      height: 24,
      leftWhite: 0.2,
      rightWhite: 0.8
    )

    let emptyDocument = Self.makeDocument(
      imageSize: imageSize,
      localBlur: LocalAdjustmentFeature(mask: .brush(BrushMask(strokes: []))) {
        GaussianBlurFeature(radius: .absolute(8))
      }
    )
    #expect(EditingCanvasView.CanvasRenderPlan(localBlur: emptyDocument.localBlur) == .viewportBase)

    // Reference: same document with no blur mask at all.
    let globalOnlyDocument = Self.makeDocument(imageSize: imageSize, localBlur: nil)

    let emptyExport = try await export(emptyDocument, source: source)
    let globalOnlyExport = try await export(globalOnlyDocument, source: source)
    let emptyPreview = try CanvasCompositionPreview.render(
      document: emptyDocument,
      source: source
    )

    // The empty-brush export must equal the no-adjustment export...
    assertImagesMatch(emptyExport, globalOnlyExport, tolerance: 2)
    // ...and the preview must match the export (same empty-brush semantics).
    assertImagesMatch(emptyPreview, emptyExport, tolerance: 4)
  }

  /// A local-adjustment effect that throws must fail the export, surfaced like
  /// a throwing global effect instead of silently exporting an image missing
  /// the adjustment.
  ///
  /// (The canvas path's release-mode degrade-to-identity is not asserted here:
  /// `applyIgnoringFailure` calls `assertionFailure`, which traps in the
  /// debug test build — the same intentional contract global effects use.)
  @Test func `Throwing local adjustment fails export`() async throws {
    let source = Self.makeSolidImage(width: 32, height: 32, white: 0.5)
    let imageSize = CGSize(width: 32, height: 32)

    let throwingLayer = LocalAdjustmentFeature(
      mask: .test(
        displayStamps: [CGPoint(x: 16, y: 16)],
        diameter: 12,
        domainHeight: imageSize.height
      )
    ) {
      [AnyImageEffect(ThrowingEffectFeature())]
    }
    let document = RendererTestDocument(
      localAdjustments: [throwingLayer],
      crop: CropFeature.test(imageSize: imageSize)
    )

    let error = await #expect(throws: (any Error).self) {
      _ = try await export(document, source: source)
    }
    #expect(error is ThrowingEffectFeature.EvaluationError)
  }

  /// The parametric `brushStamp` kernel (the export mask) must produce the
  /// falloff `(1 - smoothstep(hardness, 1, d)) * opacity` the live canvas
  /// shader also draws. If it used a hard disc or a linear ramp, painted blur
  /// edges would render wider/harder than the interactive preview showed. This
  /// samples the alpha profile of a single soft, centered stamp (so the y-flip
  /// is irrelevant) and checks that contract.
  @Test func `Export mask reproduces live canvas brush falloff`() throws {
    let canvas = 300
    let center = CGPoint(x: 150, y: 150)
    let diameter = 200.0
    let radius = diameter / 2
    let hardness = 0.5

    let mask = Mask.brush(BrushMask(strokes: [
      BrushMask.Stroke(
        stampCenters: [center],
        brush: BrushMask.Brush(diameter: diameter, hardness: hardness, opacity: 1)
      )
    ]))
    let maskCIImage = try FeatureRenderer().makeMaskImage(
      for: mask,
      extent: CGRect(x: 0, y: 0, width: canvas, height: canvas)
    )
    let maskCG = try #require(
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
    #expect(alpha(atNormalizedRadius: 0.2) > 0.95)
    #expect(alpha(atNormalizedRadius: hardness - 0.05) > 0.95)
    #expect(alpha(atNormalizedRadius: 1.1) < 0.05)

    var previous = 1.1
    for t in stride(from: 0.55, through: 1.0, by: 0.05) {
      let a = alpha(atNormalizedRadius: t)
      #expect(a <= previous + 0.02, "falloff not monotonic at t=\(t)")
      previous = a
      #expect(
        abs(a - smoothstepFalloff(t)) <= 0.08,
        "export falloff at t=\(t) (\(a)) deviates from the live brush smoothstep (\(smoothstepFalloff(t)))"
      )
    }
  }

  // MARK: - Assertions

  private func assertImagesMatch(
    _ lhs: CGImage,
    _ rhs: CGImage,
    tolerance: Int,
    sourceLocation: SourceLocation = SourceLocation(
      fileID: #fileID,
      filePath: #filePath,
      line: #line,
      column: #column
    )
  ) {
    #expect(lhs.width == rhs.width, "width", sourceLocation: sourceLocation)
    #expect(lhs.height == rhs.height, "height", sourceLocation: sourceLocation)
    let step = max(1, lhs.width / 12)
    for x in stride(from: 0, to: lhs.width, by: step) {
      for y in stride(from: 0, to: lhs.height, by: max(1, lhs.height / 6)) {
        assertPixelsMatch(
          Self.rgba(in: lhs, x: x, y: y),
          Self.rgba(in: rhs, x: x, y: y),
          tolerance: tolerance,
          label: "(\(x),\(y))",
          sourceLocation: sourceLocation
        )
      }
    }
  }

  private func assertPixelsMatch(
    _ lhs: RGBA,
    _ rhs: RGBA,
    tolerance: Int,
    label: String,
    sourceLocation: SourceLocation = SourceLocation(
      fileID: #fileID,
      filePath: #filePath,
      line: #line,
      column: #column
    )
  ) {
    func diff(_ a: UInt8, _ b: UInt8) -> Int { abs(Int(a) - Int(b)) }
    let r = diff(lhs.red, rhs.red)
    let g = diff(lhs.green, rhs.green)
    let b = diff(lhs.blue, rhs.blue)
    #expect(
      max(r, g, b) <= tolerance,
      "pixel \(label) diverged: export \(lhs) vs preview \(rhs)",
      sourceLocation: sourceLocation
    )
  }

  // MARK: - Fixtures

  /// A hard 18 px stamp painted at `displayCenter` (top-left origin, y-down),
  /// stored in working space through the production conversion.
  private static func makeLocalBlur(
    radius: CGFloat,
    displayCenter: CGPoint,
    domainHeight: CGFloat
  ) -> LocalAdjustmentFeature<GaussianBlurFeature> {
    LocalAdjustmentFeature(
      mask: .test(
        displayStamps: [displayCenter],
        diameter: 18,
        domainHeight: domainHeight
      )
    ) {
      GaussianBlurFeature(radius: .absolute(Double(radius)))
    }
  }

  private static func makeDocument(
    imageSize: CGSize,
    cropRect: CGRect? = nil,
    rotation: QuarterTurn = .zero,
    localBlur: LocalAdjustmentFeature<GaussianBlurFeature>?
  ) -> ImageEditorFeature {
    var document = ImageEditorFeature(imageSize: imageSize)
    document.effects.exposure = ExposureFeature(ev: 0.4)
    document.localBlur = localBlur
    if cropRect != nil || rotation != .zero {
      var crop = CropGuideState(cropFeature: document.crop, imageSize: imageSize)
      if let cropRect {
        crop.updateCropExtent(cropRect)
      }
      crop.rotation = rotation
      document.crop = crop.makeCropFeature()
    }
    return document
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

  private static func makeCheckerImage(
    width: Int,
    height: Int,
    cell: Int
  ) -> CGImage {
    let size = CGSize(width: width, height: height)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
      UIColor(white: 0.1, alpha: 1).setFill()
      UIRectFill(CGRect(origin: .zero, size: size))
      UIColor(white: 0.9, alpha: 1).setFill()
      for y in stride(from: 0, to: height, by: cell) {
        for x in stride(from: 0, to: width, by: cell) where (x / cell + y / cell).isMultiple(of: 2) {
          UIRectFill(CGRect(x: x, y: y, width: cell, height: cell))
        }
      }
    }.cgImage!
  }

  /// A horizontal ramp with a checker over its top half only.
  private static func makeRampedCheckerImage(
    width: Int,
    height: Int,
    cell: Int
  ) -> CGImage {
    let size = CGSize(width: width, height: height)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
      for x in 0..<width {
        UIColor(white: 0.15 + 0.7 * CGFloat(x) / CGFloat(width), alpha: 1).setFill()
        UIRectFill(CGRect(x: x, y: 0, width: 1, height: height))
      }
      UIColor(white: 1, alpha: 1).setFill()
      for y in stride(from: 0, to: height / 2, by: cell) {
        for x in stride(from: 0, to: width, by: cell) where (x / cell + y / cell).isMultiple(of: 2) {
          UIRectFill(CGRect(x: x, y: y, width: cell, height: cell))
        }
      }
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
private struct ThrowingEffectFeature: ImageEffect, Equatable {
  struct EvaluationError: Error {}

  func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    throw EvaluationError()
  }
}
