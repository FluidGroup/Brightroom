import CoreImage
import XCTest
import UIKit

@testable import BrightroomEngine
@testable import BrightroomParametric

/// Produces side-by-side image attachments on the simulator so the
/// preview-vs-export composition can be inspected visually on a real demo
/// asset with a realistic edit (preset + exposure + masked blur + crop).
///
/// The numeric parity is pinned by `EditingPreviewExportParityTests`; this
/// test exists to render shareable evidence, not to assert.
final class PreviewExportVisualEvidenceTests: XCTestCase {

  private static let context = CIContext()
  private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

  func testRenderPreviewAndExportEvidence() throws {
    let source = ImageSource(image: Asset.unsplash2.image).loadOriginalCGImage()
    let imageSize = CGSize(width: source.width, height: source.height)

    // A realistic edit: a built-in preset, a global exposure lift, and a soft
    // blur painted across a horizontal band, plus a centered crop.
    let preset = PresetFeature(
      id: .init(rawValue: "evidence.preset.warm-pop"),
      name: "WarmPop",
      identifier: "evidence.preset.warm-pop",
      effects: [
        SaturationFeature(id: .init(rawValue: "evidence.sat"), value: 0.3),
        TemperatureFeature(id: .init(rawValue: "evidence.temp"), value: 900),
        ContrastFeature(id: .init(rawValue: "evidence.contrast"), value: 0.06),
      ]
    )
    let effects = EffectPipeline(effects: [
      preset,
      ExposureFeature(id: .init(rawValue: "evidence.exposure"), value: 0.35),
    ])

    let blurLayer = LocalAdjustmentFeature(
      id: .init(rawValue: "evidence.blur"),
      maskTree: MaskTree(root: .brush(BrushMask(
        id: .init(rawValue: "evidence.brush"),
        strokes: [makeHorizontalBandStroke(imageSize: imageSize)]
      ))),
      effectPipeline: EffectPipeline(effects: [
        GaussianBlurFeature(id: .init(rawValue: "evidence.blur.kernel"), value: 60)
      ])
    )

    // 1) Original (no edit).
    attach(CIImage(cgImage: source), extent: CGRect(origin: .zero, size: imageSize), name: "1-original")

    // 2) Export of the full edit with an identity crop, and 3) the preview
    //    composition of the same edit — these must look identical.
    var fullEdit = EditingStack.Edit(crop: EditingCrop(imageSize: imageSize))
    fullEdit.effects = effects
    fullEdit.localAdjustments = [blurLayer]

    let export = try renderExport(fullEdit, source: source)
    attach(cgImage: export, name: "2-export-no-crop")

    let preview = previewComposition(fullEdit, source: source)
    attach(preview, extent: CGRect(origin: .zero, size: imageSize), name: "3-preview-no-crop")

    // 4) Export of the same edit through a centered crop, to show the crop
    //    feature composes after the effects+blur.
    let cropRect = CGRect(
      x: imageSize.width * 0.15,
      y: imageSize.height * 0.15,
      width: imageSize.width * 0.7,
      height: imageSize.height * 0.7
    ).integral
    var croppedEdit = fullEdit
    croppedEdit.crop = EditingCrop(imageSize: imageSize, cropRect: cropRect)
    let croppedExport = try renderExport(croppedEdit, source: source)
    attach(cgImage: croppedExport, name: "4-export-with-crop")

    // Leave a breadcrumb in the log for extraction.
    print("EVIDENCE_ATTACHMENTS rendered: original/export/preview/export-cropped at \(Int(imageSize.width))x\(Int(imageSize.height))")
  }

  // MARK: - Rendering

  private func renderExport(_ edit: EditingStack.Edit, source: CGImage) throws -> CGImage {
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

  private func previewComposition(_ edit: EditingStack.Edit, source: CGImage) -> CIImage {
    edit.makePreviewImage(from: CIImage(cgImage: source), purpose: .editing)
  }

  private func makeHorizontalBandStroke(imageSize: CGSize) -> BrushMaskStroke {
    let y = imageSize.height * 0.5
    let diameter = imageSize.height * 0.28
    let stamps = stride(from: imageSize.width * 0.05, through: imageSize.width * 0.95, by: diameter * 0.25)
      .map { CGPoint(x: $0, y: y) }
    return BrushMaskStroke(
      stamps: stamps,
      brush: BrushMaskBrush(diameter: Double(diameter), hardness: 0.6, opacity: 1)
    )
  }

  // MARK: - Attachments

  private func attach(_ image: CIImage, extent: CGRect, name: String) {
    guard let cg = Self.context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: Self.sRGB) else {
      return
    }
    attach(cgImage: cg, name: name)
  }

  private func attach(cgImage: CGImage, name: String) {
    let uiImage = UIImage(cgImage: cgImage)
    let attachment = XCTAttachment(image: uiImage)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
