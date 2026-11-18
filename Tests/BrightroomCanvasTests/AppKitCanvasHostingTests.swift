#if os(macOS)
import AppKit
import BrightroomEngine
import BrightroomParametric
import Metal
import SwiftUI
import Testing

@testable import BrightroomUI

/// `ImageEditorCanvas` on macOS, hosted the way an app hosts it: the AppKit
/// canvas is mounted, builds its render images, and shows the output fitted
/// after layout. Presented pixels are not checked here; the shared drawing
/// path is (`CanvasOutputRenderTests`).
@MainActor
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct AppKitCanvasHostingTests {

  private static let imageSize = CGSize(width: 400, height: 200)

  /// Owns the document, as a host app does.
  private struct Host: View {
    @State var document: ImageEditorDocument

    var body: some View {
      ImageEditorCanvas(document: $document)
        .editingTarget(nil)
    }
  }

  @Test
  func `The canvas mounts the AppKit view and shows the output fitted`() async throws {
    _ = NSApplication.shared
    let document = ImageEditorDocument(source: SourceImage(cgImage: try Self.makeImage()))
    let hostingView = NSHostingView(rootView: Host(document: document))
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 300, height: 300),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = hostingView
    window.orderFrontRegardless()
    defer {
      window.orderOut(nil)
      window.contentView = nil
      window.close()
    }

    var canvas: EditingCanvasView?
    for _ in 0..<250 {
      hostingView.layoutSubtreeIfNeeded()
      canvas = Self.findCanvas(in: hostingView)
      if let canvas,
         canvas.surface.canvasView?.hasRenderImages == true,
         canvas.surface.displayedViewport != nil {
        break
      }
      try await Task.sleep(for: .milliseconds(20))
    }

    // A placeholder in place of the AppKit canvas fails here.
    let mounted = try #require(canvas, "ImageEditorCanvas did not mount an EditingCanvasView")
    let canvasView = try #require(mounted.surface.canvasView, "The canvas has no Metal view")
    #expect(canvasView.hasRenderImages)
    #expect(canvasView.isHidden == false)
    #expect(canvasView.frame == mounted.bounds)
    #expect(mounted.outputGeometry?.outputSize == Self.imageSize)
    #expect(mounted.navigation.isFitted)

    let bounds = mounted.bounds
    try #require(bounds.width > 0 && bounds.height > 0)
    let viewport = try #require(
      mounted.surface.displayedViewport,
      "No frame was drawn after layout"
    )
    let fit = min(bounds.width / Self.imageSize.width, bounds.height / Self.imageSize.height)
    let transform = viewport.contentToCanvasTransform
    #expect(abs(transform.a - fit) < 1e-9)
    #expect(abs(transform.d - fit) < 1e-9)
    #expect(transform.b == 0 && transform.c == 0)
    #expect(abs(transform.tx - (bounds.width - Self.imageSize.width * fit) / 2) < 1e-9)
    #expect(abs(transform.ty - (bounds.height - Self.imageSize.height * fit) / 2) < 1e-9)
    #expect(viewport.contentScaleFactor == window.backingScaleFactor)

    // The renderer writes the drawable in screen order; Core Animation must
    // not flip it on the way to the screen inside the flipped host.
    let metalLayer = try #require(canvasView.layer as? CAMetalLayer)
    #expect(metalLayer.contentsAreFlipped() == false)
  }

  private static func findCanvas(in view: NSView) -> EditingCanvasView? {
    if let canvas = view as? EditingCanvasView {
      return canvas
    }
    for subview in view.subviews {
      if let canvas = findCanvas(in: subview) {
        return canvas
      }
    }
    return nil
  }

  private static func makeImage() throws -> CGImage {
    let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(
      data: nil,
      width: Int(imageSize.width),
      height: Int(imageSize.height),
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: sRGB,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(origin: .zero, size: imageSize))
    return try #require(context.makeImage())
  }
}
#endif
