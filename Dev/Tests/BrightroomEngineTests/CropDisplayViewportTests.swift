import CoreGraphics
import Foundation
import Testing

@testable import BrightroomUI

/// Pins the geometry shared by the fixed crop canvas and its input mapping.
///
/// These tests use known content landmarks rather than UIKit's animation
/// timing. They protect rotation, viewport culling, and inverse coordinates;
/// physical pinch and bounce continuity still require interaction validation.
struct CropDisplayViewportTests {

  @Test func `Mapped content corners preserve rotation and translation`() {
    // A uniformly scaled, rotated image with an offscreen origin. Rebuilding
    // this mapping from enclosing rectangles would lose both basis directions.
    let transform = CropDisplayViewport.contentTransform(
      contentSize: CGSize(width: 400, height: 300),
      origin: CGPoint(x: 35, y: -27),
      horizontalCorner: CGPoint(x: 335, y: 173),
      verticalCorner: CGPoint(x: -115, y: 198)
    )

    let landmark = CGPoint(x: 160, y: 80).applying(transform)
    #expect(abs(landmark.x - 115) < 0.000001)
    #expect(abs(landmark.y - 113) < 0.000001)

    let oppositeCorner = CGPoint(x: 400, y: 300).applying(transform)
    #expect(abs(oppositeCorner.x - 185) < 0.000001)
    #expect(abs(oppositeCorner.y - 398) < 0.000001)
  }

  @Test func `Visible content and inverse input respect a nonzero content origin`() throws {
    let viewport = try #require(CropDisplayViewport(
      contentBounds: CGRect(x: 40, y: 20, width: 400, height: 300),
      canvasBounds: CGRect(x: 0, y: 0, width: 320, height: 240),
      contentToCanvasTransform: CGAffineTransform(a: 2, b: 0, c: 0, d: 2, tx: -100, ty: -40),
      contentScaleFactor: 3
    ))

    #expect(viewport.visibleContentRect == CGRect(x: 50, y: 20, width: 160, height: 120))
    #expect(viewport.visibleCanvasFrame == CGRect(x: 0, y: 0, width: 320, height: 240))
    #expect(viewport.contentPoint(fromCanvasPoint: CGPoint(x: 120, y: 80)) == CGPoint(x: 110, y: 60))
  }

  @Test func `Quarter turn preserves letterboxing and inverse input`() throws {
    let transform = CropDisplayViewport.contentTransform(
      contentSize: CGSize(width: 400, height: 300),
      origin: CGPoint(x: 280, y: 60),
      horizontalCorner: CGPoint(x: 280, y: 380),
      verticalCorner: CGPoint(x: 40, y: 60)
    )
    let viewport = try #require(CropDisplayViewport(
      contentBounds: CGRect(x: 0, y: 0, width: 400, height: 300),
      canvasBounds: CGRect(x: 0, y: 0, width: 320, height: 480),
      contentToCanvasTransform: transform,
      contentScaleFactor: 2
    ))

    #expect(viewport.visibleContentRect == CGRect(x: 0, y: 0, width: 400, height: 300))
    #expect(viewport.visibleCanvasFrame == CGRect(x: 40, y: 60, width: 240, height: 320))
    let contentPoint = viewport.contentPoint(fromCanvasPoint: CGPoint(x: 216, y: 156))
    #expect(abs(contentPoint.x - 120) < 0.000001)
    #expect(abs(contentPoint.y - 80) < 0.000001)
  }

  @Test func `Below fit samples preserve the pinch anchor without changing the canvas`() throws {
    let contentSize = CGSize(width: 400, height: 300)
    let contentBounds = CGRect(origin: .zero, size: contentSize)
    let canvasBounds = CGRect(x: 0, y: 0, width: 320, height: 480)
    let contentAnchor = CGPoint(x: 160, y: 110)
    let canvasAnchor = CGPoint(x: 140, y: 220)
    let landmark = CGPoint(x: 210, y: 160)

    // Fit is 0.8. During UIKit's return animation the model may already report
    // that scale while presentation samples remain below fit. No viewport stage
    // may replace those samples with the model's fit rectangle or reinterpret
    // them as a top-left-anchored scale.
    let samples: [(scale: CGFloat, landmark: CGPoint)] = [
      (0.8, CGPoint(x: 180, y: 260)),
      (0.7, CGPoint(x: 175, y: 255)),
      (0.64, CGPoint(x: 172, y: 252)),
      (0.7, CGPoint(x: 175, y: 255)),
      (0.8, CGPoint(x: 180, y: 260)),
    ]

    for sample in samples {
      let origin = CGPoint(
        x: canvasAnchor.x - contentAnchor.x * sample.scale,
        y: canvasAnchor.y - contentAnchor.y * sample.scale
      )
      let transform = CropDisplayViewport.contentTransform(
        contentSize: contentSize,
        origin: origin,
        horizontalCorner: CGPoint(x: origin.x + contentSize.width * sample.scale, y: origin.y),
        verticalCorner: CGPoint(x: origin.x, y: origin.y + contentSize.height * sample.scale)
      )
      let viewport = try #require(CropDisplayViewport(
        contentBounds: contentBounds,
        canvasBounds: canvasBounds,
        contentToCanvasTransform: transform,
        contentScaleFactor: 3
      ))

      let resolvedAnchor = viewport.contentPoint(fromCanvasPoint: canvasAnchor)
      #expect(abs(resolvedAnchor.x - contentAnchor.x) < 0.000001)
      #expect(abs(resolvedAnchor.y - contentAnchor.y) < 0.000001)
      let resolvedLandmark = landmark.applying(viewport.contentToCanvasTransform)
      #expect(abs(resolvedLandmark.x - sample.landmark.x) < 0.000001)
      #expect(abs(resolvedLandmark.y - sample.landmark.y) < 0.000001)
    }
  }

  @Test func `Invalid or invisible geometry does not produce a viewport`() {
    let validBounds = CGRect(x: 0, y: 0, width: 320, height: 240)

    func viewport(
      contentBounds: CGRect = CGRect(x: 0, y: 0, width: 320, height: 240),
      canvasBounds: CGRect = CGRect(x: 0, y: 0, width: 320, height: 240),
      transform: CGAffineTransform = .identity,
      contentScaleFactor: CGFloat = 2
    ) -> CropDisplayViewport? {
      CropDisplayViewport(
        contentBounds: contentBounds,
        canvasBounds: canvasBounds,
        contentToCanvasTransform: transform,
        contentScaleFactor: contentScaleFactor
      )
    }

    #expect(viewport(contentBounds: .zero) == nil)
    #expect(viewport(canvasBounds: .zero) == nil)
    #expect(viewport(contentBounds: .infinite) == nil)
    #expect(viewport(canvasBounds: .infinite) == nil)
    #expect(viewport(canvasBounds: CGRect(x: CGFloat.nan, y: 0, width: 320, height: 240)) == nil)
    #expect(viewport(transform: CGAffineTransform(scaleX: 0, y: 1)) == nil)
    #expect(viewport(transform: CGAffineTransform(translationX: .infinity, y: 0)) == nil)
    #expect(viewport(transform: CGAffineTransform(translationX: validBounds.width * 2, y: 0)) == nil)
    #expect(viewport(contentScaleFactor: 0) == nil)
    #expect(viewport(contentScaleFactor: .infinity) == nil)
  }
}
