import CoreImage
import Foundation
import Testing
import UIKit

@testable import BrightroomEngine
@testable import BrightroomParametric
@testable import BrightroomUI

/// Pins the render-path routing that keeps CropSurface's masked-adjustment
/// preview identical to ToolSurface and the export renderer.
///
/// Every local adjustment bakes its effect into the `adjusted` layer at source
/// resolution and uses the **prepared** path (`usesPreparedBaseImage == true`),
/// the same source-resolution composite ToolSurface (`makeCropOutputRenderImages`)
/// and `BrightRoomImageRenderer` use. The cached-source path re-applies the
/// effect at drawable/screen resolution and visibly diverges for spatial effects
/// like blur.
struct CropSurfaceBlurRenderPathTests {

  private func makeLoaded(width: Int, height: Int) -> EditingStack.Loaded {
    let size = CGSize(width: width, height: height)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let cg = UIGraphicsImageRenderer(size: size, format: format).image { _ in
      UIColor(white: 0.5, alpha: 1).setFill()
      UIRectFill(CGRect(origin: .zero, size: size))
    }.cgImage!
    let ci = CIImage(cgImage: cg)
    let edit = EditingStack.Edit.test(imageSize: size)
    return EditingStack.Loaded(
      imageSource: ImageSource(cgImage: cg),
      metadata: .init(orientation: .up, imageSize: size),
      initialEditing: edit,
      currentEdit: edit,
      thumbnailCIImage: ci,
      editingSourceCGImage: cg,
      editingSourceCIImage: ci
    )
  }

  @Test func `Blur local adjustment uses prepared source-resolution path`() throws {
    let loaded = makeLoaded(width: 64, height: 48)
    let blur = EffectPipeline(effects: [GaussianBlurFeature(value: 40)])
    let images = try #require(
      EditingCanvasRenderImageFactory.makeRenderImages(
        loadedState: loaded,
        canvasSize: CGSize(width: 64, height: 48),
        mode: .localAdjustment(effect: blur)
      )
    )
    #expect(
      images.usesPreparedBaseImage,
      "Blur must use the prepared (source-res) path so CropSurface matches ToolSurface/export."
    )
  }

  @Test func `Exposure local adjustment also uses prepared path`() throws {
    let loaded = makeLoaded(width: 64, height: 48)
    let exposure = EffectPipeline(effects: [ExposureFeature(value: 0.5)])
    let images = try #require(
      EditingCanvasRenderImageFactory.makeRenderImages(
        loadedState: loaded,
        canvasSize: CGSize(width: 64, height: 48),
        mode: .localAdjustment(effect: exposure)
      )
    )
    // After removing the exposure shortcut, every local adjustment bakes its
    // effect and uses the prepared path.
    #expect(images.usesPreparedBaseImage)
  }

  /// ToolSurface already used the prepared path; this guards that they agree.
  @Test func `Tool surface blur also uses prepared path`() throws {
    let loaded = makeLoaded(width: 64, height: 48)
    let crop = CropEditingState(
      cropFeature: CropFeature.test(
        imageSize: CGSize(width: 64, height: 48),
        cropRect: CGRect(x: 8, y: 6, width: 48, height: 36)
      ),
      imageSize: CGSize(width: 64, height: 48)
    )
    let geometry = try #require(EditingCanvasCropOutputGeometry(crop: crop))
    let blur = EffectPipeline(effects: [GaussianBlurFeature(value: 40)])
    let images = try #require(
      EditingCanvasRenderImageFactory.makeCropOutputRenderImages(
        loadedState: loaded,
        geometry: geometry,
        mode: .localAdjustment(effect: blur)
      )
    )
    #expect(images.usesPreparedBaseImage)
  }
}
