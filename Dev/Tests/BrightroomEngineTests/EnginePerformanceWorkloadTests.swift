import CoreImage
import XCTest
import UIKit

@testable import BrightroomEngine
@testable import BrightroomParametric

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
/// - export render (`BrightRoomImageRenderer.renderRevison2`)
/// - preview composition (`Edit.makePreviewImage(.editing)`)
/// - CPU brush-mask raster (`LocalAdjustmentMaskRasterStore` cache miss)
/// - parametric evaluation (`EffectPipeline.apply` / feature recipes)
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
    let source = ImageSource(image: Asset.unsplash2.image).loadOriginalCGImage()
    let document = Self.makeDocument(imageSize: CGSize(width: source.width, height: source.height))
    measure(metrics: benchMetrics, options: benchOptions) {
      _ = try? exportRender(document, source: source)
    }
  }

  func testMeasurePreviewComposition() throws {
    let source = ImageSource(image: Asset.unsplash2.image).loadOriginalCGImage()
    let ci = CIImage(cgImage: source)
    let document = Self.makeDocument(imageSize: CGSize(width: source.width, height: source.height))
    measure(metrics: benchMetrics, options: benchOptions) {
      previewComposition(document, source: ci)
    }
  }

  func testMeasureMaskRasterCacheMiss() throws {
    let source = ImageSource(image: Asset.unsplash2.image).loadOriginalCGImage()
    let imageSize = CGSize(width: source.width, height: source.height)
    var salt = 0
    measure(metrics: benchMetrics, options: benchOptions) {
      maskRasterCacheMiss(imageSize: imageSize, salt: salt)
      salt += 1
    }
  }

  func testMeasureParametricEval() throws {
    let source = ImageSource(image: Asset.unsplash2.image).loadOriginalCGImage()
    let ci = CIImage(cgImage: source)
    measure(metrics: benchMetrics, options: benchOptions) {
      parametricEvaluate(over: ci)
    }
  }

  // MARK: - Hot paths

  @inline(never)
  private func exportRender(_ edit: EditingStack.Edit, source: CGImage) throws -> CGImage {
    let renderer = BrightRoomImageRenderer(source: ImageSource(cgImage: source), orientation: .up)
    renderer.edit = .init(
      croppingRect: edit.crop,
      operations: edit.features.compactMap { feature in
        switch feature.payload {
        case .effects(let p): return p.hasEnabledEffects ? .effects(p) : nil
        case .localAdjustment(let a): return .localAdjustment(a)
        case .crop: return nil
        }
      }
    )
    return try renderer.render(options: .init(workingColorSpace: Self.sRGB)).cgImage
  }

  @inline(never)
  private func previewComposition(_ edit: EditingStack.Edit, source: CIImage) {
    let composed = edit.makePreviewImage(from: source, purpose: .editing)
    _ = Self.context.createCGImage(composed, from: source.extent)
  }

  @inline(never)
  private func maskRasterCacheMiss(imageSize: CGSize, salt: Int) {
    // A fresh stamp position each call forces a new BrushMask ⇒ cache miss.
    let tree = MaskTree(root: .brush(BrushMask(strokes: [
      BrushMaskStroke(
        stamps: [CGPoint(x: 100 + (salt % 50), y: 100 + (salt % 50))],
        brush: BrushMaskBrush(diameter: imageSize.height * 0.3, hardness: 0.6, opacity: 1)
      )
    ])))
    _ = tree.engineMakeMaskImage(size: imageSize)
  }

  @inline(never)
  private func parametricEvaluate(over source: CIImage) {
    let pipeline = Self.makeEffectPipeline()
    let evaluated = (try? pipeline.apply(to: source, context: FeatureEvaluationContext())) ?? source
    _ = Self.context.createCGImage(evaluated, from: source.extent)
  }

  // MARK: - Fixtures

  private static let cachedMaskTree = MaskTree(root: .brush(BrushMask(
    id: .init(rawValue: "perf.cached.mask"),
    strokes: [
      BrushMaskStroke(
        stamps: [CGPoint(x: 400, y: 300)],
        brush: BrushMaskBrush(diameter: 500, hardness: 0.6, opacity: 1)
      )
    ]
  )))

  private static func makeEffectPipeline() -> EffectPipeline {
    EffectPipeline(effects: [
      PresetFeature(
        id: .init(rawValue: "perf.preset"),
        name: "Perf",
        identifier: "perf.preset",
        effects: [
          SaturationFeature(id: .init(rawValue: "perf.sat"), value: 0.3),
          TemperatureFeature(id: .init(rawValue: "perf.temp"), value: 900),
          ContrastFeature(id: .init(rawValue: "perf.contrast"), value: 0.06),
        ]
      ),
      ExposureFeature(id: .init(rawValue: "perf.exposure"), value: 0.35),
      HighlightsFeature(id: .init(rawValue: "perf.highlights"), value: 0.2),
      ShadowsFeature(id: .init(rawValue: "perf.shadows"), value: -0.15),
      VignetteFeature(id: .init(rawValue: "perf.vignette"), value: 0.5),
    ])
  }

  private static func makeDocument(imageSize: CGSize) -> EditingStack.Edit {
    var edit = EditingStack.Edit(crop: EditingCrop(imageSize: imageSize))
    edit.effects = makeEffectPipeline()
    edit.localAdjustments = [
      LocalAdjustmentFeature(
        id: .init(rawValue: "perf.local"),
        maskTree: cachedMaskTree,
        effectPipeline: EffectPipeline(effects: [
          GaussianBlurFeature(id: .init(rawValue: "perf.local.blur"), value: 60)
        ])
      )
    ]
    edit.crop = EditingCrop(
      imageSize: imageSize,
      cropRect: CGRect(
        x: imageSize.width * 0.1,
        y: imageSize.height * 0.1,
        width: imageSize.width * 0.8,
        height: imageSize.height * 0.8
      ).integral
    )
    return edit
  }
}
