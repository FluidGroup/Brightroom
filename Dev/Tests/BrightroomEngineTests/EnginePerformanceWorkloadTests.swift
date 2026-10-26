import CoreImage
import XCTest
import UIKit

@testable import BrightroomEngine
@testable import BrightroomParametric
@testable import BrightroomUI

/// Per-path performance benchmarks for the engine hot paths, with wall-clock
/// and CPU metrics (CPU Instructions Retired is the device-portable one).
///
/// These are the reliable headless substitute for an Instruments Time Profiler
/// trace: `xctrace` cannot sample iOS-Simulator processes headlessly, and the
/// simulator's GPU path is not device-representative anyway. `measure`'s CPU
/// metrics are deterministic and comparable across runs, so these double as
/// regression guards. They add ~8s; run the suite normally, or target one with
/// `-only-testing:BrightroomEngineTests/EnginePerformanceWorkloadTests`.
///
/// Covered hot paths:
/// - export render (`EditingDocument.render`)
/// - preview composition (the document with its crop neutralized, over the
///   full-size source, as the old `Edit.makePreviewImage(.editing)` did)
/// - brush-mask raster (`FeatureRenderer.makeMaskImage` via
///   `BrushMaskImageProcessor`)
/// - parametric evaluation (`ImageEditorFeature.Effects.apply` / feature recipes)
final class EnginePerformanceWorkloadTests: XCTestCase {

  private static let context = CIContext()
  private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

  private var benchMetrics: [XCTMetric] { [XCTClockMetric(), XCTCPUMetric()] }
  private var benchOptions: XCTMeasureOptions {
    let options = XCTMeasureOptions()
    options.iterationCount = 8
    return options
  }

  // MARK: - Benchmarks

  func testMeasureExportRender() throws {
    let source = Asset.unsplash2.image.decodedCGImageForTesting
    let document = Self.makeDocument(imageSize: CGSize(width: source.width, height: source.height))
    measure(metrics: benchMetrics, options: benchOptions) {
      _ = try? exportRender(document, source: source)
    }
  }

  func testMeasurePreviewComposition() throws {
    let source = Asset.unsplash2.image.decodedCGImageForTesting
    let ci = CIImage(cgImage: source)
    let document = Self.makeDocument(imageSize: CGSize(width: source.width, height: source.height))
    measure(metrics: benchMetrics, options: benchOptions) {
      previewComposition(document, source: ci)
    }
  }

  func testMeasureMaskRasterCacheMiss() throws {
    let source = Asset.unsplash2.image.decodedCGImageForTesting
    let imageSize = CGSize(width: source.width, height: source.height)
    var salt = 0
    measure(metrics: benchMetrics, options: benchOptions) {
      maskRasterCacheMiss(imageSize: imageSize, salt: salt)
      salt += 1
    }
  }

  func testMeasureParametricEval() throws {
    let source = Asset.unsplash2.image.decodedCGImageForTesting
    let ci = CIImage(cgImage: source)
    measure(metrics: benchMetrics, options: benchOptions) {
      parametricEvaluate(over: ci)
    }
  }

  // MARK: - Hot paths

  @inline(never)
  private func exportRender(_ document: ImageEditorFeature, source: CGImage) throws -> CGImage {
    // `measure {}` is synchronous; call the synchronous render core directly so
    // the benchmark measures the render work itself, not the async/executor hop.
    return try EditingDocument(source: SourceImage(cgImage: source), feature: document)
      .renderForTesting(options: .init(outputColorSpace: Self.sRGB), device: .automatic)
      .cgImage
  }

  @inline(never)
  private func previewComposition(_ document: ImageEditorFeature, source: CIImage) {
    // The document is authored in full-resolution coordinates, so the preview
    // evaluates over the full-size source, with the crop neutralized.
    let preview = document.withCropNeutralized(imageSize: source.extent.size)
    guard let composed = try? FeatureRenderer().makeImage(from: source, feature: preview) else {
      return
    }
    _ = Self.context.createCGImage(composed, from: source.extent)
  }

  @inline(never)
  private func maskRasterCacheMiss(imageSize: CGSize, salt: Int) {
    // A fresh stamp position each call forces a new BrushMask ⇒ cache miss.
    let mask = Mask.brush(BrushMask(strokes: [
      BrushMask.Stroke(
        stampCenters: [CGPoint(x: 100 + (salt % 50), y: 100 + (salt % 50))],
        brush: BrushMask.Brush(diameter: imageSize.height * 0.3, hardness: 0.6, opacity: 1)
      )
    ]))
    _ = try? FeatureRenderer().makeMaskImage(for: mask, extent: CGRect(origin: .zero, size: imageSize))
  }

  @inline(never)
  private func parametricEvaluate(over source: CIImage) {
    let effects = Self.makeEffects()
    let context = FeatureEvaluationContext()
    let adjusted = (try? effects.apply(to: source, context: context)) ?? source
    // The vignette is a top-level member of the feature, after the crop; the
    // workload evaluates it as well.
    let evaluated = (try? VignetteFeature(value: 0.5).apply(to: adjusted, context: context)) ?? adjusted
    _ = Self.context.createCGImage(evaluated, from: source.extent)
  }

  // MARK: - Fixtures

  private static let cachedMask = Mask.brush(BrushMask(
    strokes: [
      BrushMask.Stroke(
        stampCenters: [CGPoint(x: 400, y: 300)],
        brush: BrushMask.Brush(diameter: 500, hardness: 0.6, opacity: 1)
      )
    ]
  ))

  private static func makeEffects() -> ImageEditorFeature.Effects {
    ImageEditorFeature.Effects(
      preset: FilterFeature(
        name: "Perf",
        id: "perf.preset",
        effects: [
          AnyImageEffect(SaturationFeature(value: 0.3)),
          AnyImageEffect(WhiteBalanceFeature(temperature: 900)),
          AnyImageEffect(ContrastFeature(value: 0.06)),
        ]
      ),
      exposure: ExposureFeature(ev: 0.35),
      highlights: HighlightsFeature(value: 0.2),
      shadows: ShadowsFeature(value: -0.15)
    )
  }

  private static func makeDocument(imageSize: CGSize) -> ImageEditorFeature {
    var document = ImageEditorFeature(imageSize: imageSize)
    document.effects = makeEffects()
    document.vignette = VignetteFeature(value: 0.5)
    document.localBlur = LocalAdjustmentFeature(mask: cachedMask) {
      GaussianBlurFeature(radius: .proportional(60))
    }
    var crop = CropGuideState(cropFeature: document.crop, imageSize: imageSize)
    crop.updateCropExtent(
      CGRect(
        x: imageSize.width * 0.1,
        y: imageSize.height * 0.1,
        width: imageSize.width * 0.8,
        height: imageSize.height * 0.8
      ).integral
    )
    document.crop = crop.makeCropFeature()
    return document
  }
}
