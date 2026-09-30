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
/// and `EditingDocument.render` use. The cached-source path re-applies the
/// effect at drawable/screen resolution and visibly diverges for spatial effects
/// like blur.
struct CropSurfaceBlurRenderPathTests {

  private func makeSource(width: Int, height: Int) -> CIImage {
    let size = CGSize(width: width, height: height)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let cg = UIGraphicsImageRenderer(size: size, format: format).image { _ in
      UIColor(white: 0.5, alpha: 1).setFill()
      UIRectFill(CGRect(origin: .zero, size: size))
    }.cgImage!
    return CIImage(cgImage: cg)
  }

  @Test func `Blur local adjustment uses prepared source-resolution path`() throws {
    let source = makeSource(width: 64, height: 48)
    let blur = AnyImageEffect(GaussianBlurFeature(radius: .proportional(40)))
    let images = try #require(
      EditingCanvasRenderImageFactory.makeRenderImages(
        editingSourceImage: source,
        effects: nil,
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
    let source = makeSource(width: 64, height: 48)
    let exposure = AnyImageEffect(ExposureFeature(ev: 0.5))
    let images = try #require(
      EditingCanvasRenderImageFactory.makeRenderImages(
        editingSourceImage: source,
        effects: nil,
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
    let source = makeSource(width: 64, height: 48)
    let crop = CropGuideState(
      cropFeature: CropFeature.test(
        imageSize: CGSize(width: 64, height: 48),
        topLeftRect: CGRect(x: 8, y: 6, width: 48, height: 36)
      ),
      imageSize: CGSize(width: 64, height: 48)
    )
    let geometry = try #require(EditingCanvasCropOutputGeometry(crop: crop))
    let blur = AnyImageEffect(GaussianBlurFeature(radius: .proportional(40)))
    let images = try #require(
      EditingCanvasRenderImageFactory.makeCropOutputRenderImages(
        editingSourceImage: source,
        effects: nil,
        geometry: geometry,
        mode: .localAdjustment(effect: blur)
      )
    )
    #expect(images.usesPreparedBaseImage)
  }
}
