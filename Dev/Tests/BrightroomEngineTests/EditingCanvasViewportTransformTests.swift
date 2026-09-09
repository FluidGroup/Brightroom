import CoreGraphics
import Foundation
import Testing

@testable import BrightroomUI

/// Protects the content-to-drawable transform used by image layers and brushes.
///
/// A fixed Metal canvas renders rotation in its affine mapping. The enclosing
/// canvas rectangle must never replace that mapping or determine brush radius.
struct EditingCanvasViewportTransformTests {

  @Test func `Affine viewport keeps offset and drawable scale`() {
    let viewport = _EditingCanvasMTKView.Viewport(
      visibleContentRect: CGRect(x: 40, y: 20, width: 200, height: 100),
      contentToCanvasTransform: CGAffineTransform(a: 1.5, b: 0, c: 0, d: 1.5, tx: -50, ty: 0)
    )
    let transform = viewport.contentToTextureTransform(
      canvasSize: CGSize(width: 320, height: 240),
      textureSize: CGSize(width: 960, height: 720)
    )

    #expect(CGPoint(x: 40, y: 20).applying(transform) == CGPoint(x: 30, y: 90))
    #expect(CGPoint(x: 240, y: 120).applying(transform) == CGPoint(x: 930, y: 540))
    #expect(CGPoint(x: 140, y: 70).applying(transform) == CGPoint(x: 480, y: 315))
  }

  @Test func `Rotated content landmark lands in the same texture coordinates as its brush`() {
    let viewport = _EditingCanvasMTKView.Viewport(
      visibleContentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
      // Rendering receives only the sampled transform, even when the scroll
      // view's model has already settled at a different scale.
      contentToCanvasTransform: CGAffineTransform(a: 0, b: 0.8, c: -0.8, d: 0, tx: 280, ty: 60)
    )
    let transform = viewport.contentToTextureTransform(
      canvasSize: CGSize(width: 320, height: 480),
      textureSize: CGSize(width: 960, height: 1440)
    )

    // A content point (120, 80) appears at canvas point (216, 156). Both the
    // rendered image and a stamp at that point must land at these same pixels.
    let texturePoint = CGPoint(x: 120, y: 80).applying(transform)
    #expect(abs(texturePoint.x - 648) < 0.000001)
    #expect(abs(texturePoint.y - 468) < 0.000001)
  }

  @Test(arguments: [0.0, Double.pi / 6, Double.pi / 4, Double.pi / 2])
  func `Rotation does not inflate the image space brush radius`(radians: Double) {
    let viewport = _EditingCanvasMTKView.Viewport(
      visibleContentRect: CGRect(x: 30, y: 10, width: 400, height: 300),
      contentToCanvasTransform: CGAffineTransform(scaleX: 1.25, y: 1.25)
        .concatenating(CGAffineTransform(rotationAngle: CGFloat(radians)))
        .concatenating(CGAffineTransform(translationX: 75, y: 20))
    )
    let radius = viewport.textureRadius(
      forContentRadius: 12,
      canvasSize: CGSize(width: 320, height: 480),
      textureSize: CGSize(width: 960, height: 1440)
    )

    // 12 content pixels × 1.25 canvas points/pixel × 3 drawable pixels/point.
    // An enclosing-rectangle scale would enlarge this at 30° and 45°.
    #expect(abs(radius - 45) < 0.000001)
  }

  @Test func `Drawable rounding changes pixel mapping without shifting the content origin`() {
    let viewport = _EditingCanvasMTKView.Viewport(
      visibleContentRect: CGRect(x: 0, y: 0, width: 100, height: 80),
      contentToCanvasTransform: CGAffineTransform(translationX: 5, y: 7)
    )
    let canvasSize = CGSize(width: 100, height: 80)
    let textureSize = CGSize(width: 201, height: 159)
    let transform = viewport.contentToTextureTransform(canvasSize: canvasSize, textureSize: textureSize)
    let texturePoint = CGPoint(x: 15, y: 23).applying(transform)

    #expect(abs(texturePoint.x - 40.2) < 0.000001)
    #expect(abs(texturePoint.y - 59.625) < 0.000001)
    let radius = viewport.textureRadius(
      forContentRadius: 10,
      canvasSize: canvasSize,
      textureSize: textureSize
    )
    #expect(abs(radius - 20) < 0.02)
  }
}
