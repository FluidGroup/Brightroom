import CoreImage
import Foundation
import Metal
import Testing
import UIKit

@testable import BrightroomEngine
@testable import BrightroomParametric
@testable import BrightroomUI

/// Produces side-by-side image attachments on the simulator so the
/// preview-vs-export composition can be inspected visually on a real demo
/// asset with a realistic edit (preset + exposure + masked blur + crop).
///
/// The numeric parity is pinned by `EditingPreviewExportParityTests`; this
/// test exists to render shareable evidence, not to assert.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct PreviewExportVisualEvidenceTests {

  private static let context = CIContext()
  private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

  @Test func `Render preview and export evidence`() async throws {
    let source = Asset.unsplash2.image.decodedCGImageForTesting
    let imageSize = CGSize(width: source.width, height: source.height)

    // A realistic edit: a built-in preset, a global exposure lift, and a soft
    // blur painted across a horizontal band, plus a centered crop.
    let preset = PresetFeature(
      name: "WarmPop",
      identifier: "evidence.preset.warm-pop",
      effects: [
        AnyImageEffect(SaturationFeature(value: 0.3)),
        AnyImageEffect(TemperatureFeature(value: 900)),
        AnyImageEffect(ContrastFeature(value: 0.06)),
      ]
    )
    var document = ImageEditorFeature(imageSize: imageSize)
    document.effects.preset = preset
    document.effects.exposure = ExposureFeature(value: 0.35)
    // The band is centered vertically, so its working-space stamps equal the
    // display ones.
    document.localBlur = LocalAdjustmentFeature(
      mask: .brush(BrushMask(
        strokes: [makeHorizontalBandStroke(imageSize: imageSize)]
      ))
    ) {
      GaussianBlurFeature(value: 60)
    }

    // 1) Original (no edit).
    attach(CIImage(cgImage: source), extent: CGRect(origin: .zero, size: imageSize), name: "1-original")

    // 2) Export of the full edit with an identity crop, and 3) the canvas
    //    composition of the same edit — these must look identical.
    let export = try await renderExport(document, source: source)
    attach(cgImage: export, name: "2-export-no-crop")

    let preview = try CanvasCompositionPreview.render(document: document, source: source)
    attach(cgImage: preview, name: "3-preview-no-crop")

    // 4) Export of the same edit through a centered crop, to show the crop
    //    feature composes after the effects+blur.
    let cropRect = CGRect(
      x: imageSize.width * 0.15,
      y: imageSize.height * 0.15,
      width: imageSize.width * 0.7,
      height: imageSize.height * 0.7
    ).integral
    var croppedDocument = document
    var crop = CropEditingState(cropFeature: croppedDocument.crop, imageSize: imageSize)
    crop.updateCropExtent(cropRect)
    croppedDocument.setCrop(crop)
    let croppedExport = try await renderExport(croppedDocument, source: source)
    attach(cgImage: croppedExport, name: "4-export-with-crop")

    // Leave a breadcrumb in the log for extraction.
    print("EVIDENCE_ATTACHMENTS rendered: original/export/preview/export-cropped at \(Int(imageSize.width))x\(Int(imageSize.height))")
  }

  // MARK: - Rendering

  private func renderExport(_ document: ImageEditorFeature, source: CGImage) async throws -> CGImage {
    try await EditingDocument(image: SourceImage(cgImage: source), feature: document)
      .render(options: .init(outputColorSpace: Self.sRGB))
      .cgImage
  }

  private func makeHorizontalBandStroke(imageSize: CGSize) -> BrushMask.Stroke {
    let y = imageSize.height * 0.5
    let diameter = imageSize.height * 0.28
    let stamps = stride(from: imageSize.width * 0.05, through: imageSize.width * 0.95, by: diameter * 0.25)
      .map { CGPoint(x: $0, y: y) }
    return BrushMask.Stroke(
      stampCenters: stamps,
      brush: BrushMask.Brush(diameter: Double(diameter), hardness: 0.6, opacity: 1)
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
    if let data = uiImage.pngData() {
      Attachment.record(data, named: "\(name).png")
    }
  }
}
