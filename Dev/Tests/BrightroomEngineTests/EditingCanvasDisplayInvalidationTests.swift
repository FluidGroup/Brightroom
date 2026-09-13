import CoreImage
import MetalKit
import Testing
import UIKit

@testable import BrightroomUI

/// Uses a real Metal view to check that idle frames stop before drawable
/// acquisition, and that each kind of changed input resumes presentation.
@MainActor
struct EditingCanvasDisplayInvalidationTests {

  @Test func `An unchanged canvas stays idle and changed images or geometry redraw`() throws {
    let (window, canvas) = try makeCanvas()
    defer { window.isHidden = true }
    let viewport = EditingCanvasRenderer.Viewport(
      visibleContentRect: CGRect(x: 0, y: 0, width: 80, height: 60),
      contentToCanvasTransform: .identity
    )
    canvas.setViewport(viewport)
    canvas.setRenderImages(images(.red))
    try #require(canvas.drawIfNeeded(), "Initial frame needs a drawable")

    for _ in 0..<120 {
      canvas.setViewport(viewport)
      canvas.setCommittedStrokes([])
      #expect(canvas.drawIfNeeded() == false)
    }

    // Geometry alone cannot identify image/effect replacement at the same size.
    canvas.setRenderImages(images(.blue))
    #expect(canvas.drawIfNeeded())
    #expect(canvas.drawIfNeeded() == false)

    var moved = viewport
    moved.contentToCanvasTransform = .init(translationX: 5, y: 8)
    canvas.setViewport(moved)
    #expect(canvas.drawIfNeeded())
    #expect(canvas.drawIfNeeded() == false)

    canvas.drawableSize = CGSize(width: 160, height: 120)
    #expect(canvas.drawIfNeeded())
    #expect(canvas.drawIfNeeded() == false)

    canvas.setNeedsCanvasDisplay()
    #expect(canvas.drawIfNeeded())
    #expect(canvas.drawIfNeeded() == false)
  }

  @Test func `Stroke changes and cancellation redraw even with an unchanged viewport`() throws {
    let (window, canvas) = try makeCanvas()
    defer { window.isHidden = true }
    canvas.setViewport(.init(
      visibleContentRect: CGRect(x: 0, y: 0, width: 80, height: 60),
      contentToCanvasTransform: .identity
    ))
    canvas.setRenderImages(images(.gray))
    let brush = EditingCanvasBrush(size: 12)
    canvas.configure(brush: brush, smoothing: .init(algorithm: .raw, strength: 0))
    try #require(canvas.drawIfNeeded())

    canvas.beginStroke(at: CGPoint(x: 20, y: 20))
    #expect(canvas.drawIfNeeded())
    #expect(canvas.drawIfNeeded() == false)
    canvas.appendStroke(points: [CGPoint(x: 40, y: 20)])
    #expect(canvas.drawIfNeeded())
    canvas.cancelStroke()
    #expect(canvas.drawIfNeeded())
    #expect(canvas.drawIfNeeded() == false)

    // Ending without any further movement still removes the active stroke.
    // A host can supply the committed record in a subsequent input update.
    canvas.beginStroke(at: CGPoint(x: 20, y: 20))
    #expect(canvas.drawIfNeeded())
    canvas.endStroke(at: CGPoint(x: 20, y: 20))
    #expect(canvas.drawIfNeeded())
    let records = [EditingCanvasStrokeRecord(stamps: [CGPoint(x: 20, y: 20)], brush: brush)]
    canvas.setCommittedStrokes(records)
    #expect(canvas.drawIfNeeded())
    canvas.setCommittedStrokes(records)
    #expect(canvas.drawIfNeeded() == false)
    canvas.setCommittedStrokes([])
    #expect(canvas.drawIfNeeded())
  }

  private func makeCanvas() throws -> (UIWindow, _EditingCanvasMTKView) {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let frame = CGRect(x: 0, y: 0, width: 80, height: 60)
    let window: UIWindow
    if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
      window = UIWindow(windowScene: scene)
    } else {
      window = UIWindow(frame: frame)
    }
    let controller = UIViewController()
    window.rootViewController = controller
    let canvas = _EditingCanvasMTKView(canvasSize: frame.size, device: device)
    canvas.frame = frame
    controller.view.addSubview(canvas)
    window.isHidden = false
    controller.view.layoutIfNeeded()
    canvas.layoutIfNeeded()
    return (window, canvas)
  }

  private func images(_ color: CIColor) -> EditingCanvasRenderImages {
    let image = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 80, height: 60))
    return .init(
      source: image, effects: .init(), base: image, adjusted: image,
      localEffect: .init(), usesPreparedBaseImage: false
    )
  }
}
