#if os(macOS)
import AppKit
import CoreGraphics
import Metal
import SwiftUI
import Testing

// Public API only: this file plays the role of a host app that shows the
// canvas over a shared preview and drives it. It must not need `@testable`
// access, and it uses no package symbols.
import BrightroomEngine
import BrightroomParametric
import BrightroomUI

/// `ImageEditorCanvas` on macOS, used as a host uses it: inside a
/// `PreviewSourceReader` and an `ImageEditorCanvasReader`, in a window that
/// never shows on a screen. The reader's proxy zooms the canvas, and the
/// canvas reports its zoom and the pixel under the pointer, samples points,
/// keeps a fit margin, and takes a name for VoiceOver.
///
/// The window's content is 300 points square, so the 400 × 200 image fits at
/// 0.75: 300 × 150 points, 75 points below the top.
@MainActor
@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct CanvasPublicAPITests {

  private static let imageSize = CGSize(width: 400, height: 200)

  /// What the host received from the canvas, and the reader's proxy.
  @MainActor
  private final class Recorder {
    var proxy: ImageEditorCanvasProxy?
    var zooms: [ImageEditorCanvas.Zoom] = []
    var pointers: [CGPoint?] = []
    var samples: [CGPoint] = []
  }

  /// The canvas as the documentation shows it: one loader for the image,
  /// shared through a `PreviewSourceReader` given an identity per image, and
  /// a reader for the commands.
  private struct Host: View {
    let document: ImageEditorDocument
    let recorder: Recorder
    var areAnimationsEnabled = true
    var fitMargin: CGFloat = 0
    var samplesPoints = false
    var accessibilityLabel: String?

    var body: some View {
      PreviewSourceReader(source: document.source) { loader in
        ImageEditorCanvasReader { canvas in
          labelled(
            ImageEditorCanvas(
              document: .constant(document),
              previewSourceLoader: loader,
              areAnimationsEnabled: areAnimationsEnabled
            )
            .editingTarget(nil)
            .fitMargin(fitMargin)
            .onZoomChange { recorder.zooms.append($0) }
            .onPointerChange { recorder.pointers.append($0) }
            .pointSampling(sampling)
          )
          .onAppear { recorder.proxy = canvas }
        }
      }
      .id(document.source)
    }

    /// Records the sampled points while the host samples them.
    private var sampling: (@MainActor (CGPoint) -> Void)? {
      guard samplesPoints else {
        return nil
      }
      return { [recorder] in recorder.samples.append($0) }
    }

    private func labelled(_ canvas: ImageEditorCanvas) -> ImageEditorCanvas {
      guard let accessibilityLabel else {
        return canvas
      }
      return canvas.canvasAccessibilityLabel(accessibilityLabel)
    }
  }

  // MARK: - Zoom

  @Test
  func `A reader's proxy zooms the canvas to a fraction, and the zoom is reported before the command returns`() async throws {
    let recorder = Recorder()
    let (hostingView, window) = try Self.host(Host(document: try Self.makeDocument(), recorder: recorder))
    defer { Self.close(window) }

    // The first frame reports the fit.
    try await Self.wait(in: hostingView, "The canvas did not report its fit") {
      recorder.zooms.isEmpty == false && recorder.proxy != nil
    }
    let fitted = try #require(recorder.zooms.last)
    #expect(fitted.isFitted)
    #expect(fitted.fraction == 0)
    #expect(abs(fitted.fitScale - 0.75) < 1e-9)
    #expect(fitted.maximumScale > fitted.fitScale)
    #expect(fitted.displayScale == window.backingScaleFactor)
    #expect(fitted.percent == Int((0.75 * window.backingScaleFactor * 100).rounded()))

    let proxy = try #require(recorder.proxy)
    let reported = recorder.zooms.count
    proxy.zoom(toFraction: 0.5)
    #expect(recorder.zooms.count == reported + 1)
    let zoomed = try #require(recorder.zooms.last)
    #expect(abs(zoomed.fraction - 0.5) < 1e-9)
    // Half the logarithmic way from the fit to the maximum.
    let expected = fitted.fitScale * (fitted.maximumScale / fitted.fitScale).squareRoot()
    #expect(abs(zoomed.scale - expected) < 1e-9)
    #expect(zoomed.fitScale == fitted.fitScale)
    #expect(zoomed.isFitted == false)
    #expect(zoomed.isAtMaximum == false)
  }

  @Test
  func `With animations off, the zoom commands apply at once and are reported before they return`() async throws {
    let recorder = Recorder()
    let (hostingView, window) = try Self.host(
      Host(document: try Self.makeDocument(), recorder: recorder, areAnimationsEnabled: false)
    )
    defer { Self.close(window) }
    try await Self.wait(in: hostingView, "The canvas did not report its fit") {
      recorder.zooms.isEmpty == false && recorder.proxy != nil
    }
    let proxy = try #require(recorder.proxy)
    let fit = try #require(recorder.zooms.last).fitScale

    proxy.zoomIn()
    #expect(abs((recorder.zooms.last?.scale ?? 0) - 2 * fit) < 1e-9)
    proxy.zoomIn()
    #expect(abs((recorder.zooms.last?.scale ?? 0) - 4 * fit) < 1e-9)
    proxy.zoomOut()
    #expect(abs((recorder.zooms.last?.scale ?? 0) - 2 * fit) < 1e-9)
    proxy.zoomToFit()
    #expect(recorder.zooms.last?.isFitted == true)

    // At the fit a step out changes nothing, and nothing is reported.
    let atFit = recorder.zooms.count
    proxy.zoomOut()
    #expect(recorder.zooms.count == atFit)

    proxy.zoom(toFraction: 1)
    #expect(recorder.zooms.last?.isAtMaximum == true)
    // At the maximum a step in changes nothing either.
    let atMaximum = recorder.zooms.count
    proxy.zoomIn()
    #expect(recorder.zooms.count == atMaximum)
  }

  @Test(.enabled(if: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false))
  func `With animations on, a zoom step starts a motion and is not reported before it returns`() async throws {
    let recorder = Recorder()
    let (hostingView, window) = try Self.host(Host(document: try Self.makeDocument(), recorder: recorder))
    defer { Self.close(window) }
    try await Self.wait(in: hostingView, "The canvas did not report its fit") {
      recorder.zooms.isEmpty == false && recorder.proxy != nil
    }
    let proxy = try #require(recorder.proxy)
    let reported = recorder.zooms.count

    // The motion's frames report the zoom; the command only starts it.
    proxy.zoomIn()
    #expect(recorder.zooms.count == reported)

    // A zoom to a fraction applies at once, animations or not.
    proxy.zoom(toFraction: 1)
    #expect(recorder.zooms.count == reported + 1)
    #expect(recorder.zooms.last?.isAtMaximum == true)
  }

  @Test
  func `A fit margin leaves room around the output at the fit`() async throws {
    let recorder = Recorder()
    let (hostingView, window) = try Self.host(
      Host(document: try Self.makeDocument(), recorder: recorder, fitMargin: 12)
    )
    defer { Self.close(window) }
    try await Self.wait(in: hostingView, "The canvas did not report its fit") {
      recorder.zooms.isEmpty == false
    }

    // The 400 × 200 output fits the 276 points inside the margins at 0.69,
    // where it would fit the whole 300 points at 0.75.
    let fitted = try #require(recorder.zooms.last)
    #expect(fitted.isFitted)
    #expect(abs(fitted.fitScale - 0.69) < 1e-9)
  }

  // MARK: - Pointer and sampling

  @Test
  func `The pointer is reported as the output pixel under it, and nil off the image`() async throws {
    let recorder = Recorder()
    let (hostingView, window) = try Self.host(Host(document: try Self.makeDocument(), recorder: recorder))
    defer { Self.close(window) }
    try await Self.wait(in: hostingView, "The canvas did not report its fit") {
      recorder.zooms.isEmpty == false
    }

    // Window coordinates run up: 149 points up is 151 points down, over
    // output (201.3, 101.3), reported as a whole pixel at once.
    try Self.movePointer(to: CGPoint(x: 151, y: 149), in: window)
    #expect(recorder.pointers == [CGPoint(x: 201, y: 101)])

    // Above the letterboxed output there is no pixel.
    try Self.movePointer(to: CGPoint(x: 151, y: 260), in: window)
    #expect(recorder.pointers == [CGPoint(x: 201, y: 101), nil])
  }

  @Test
  func `While points are sampled, a click on the image reports the output point under it`() async throws {
    let recorder = Recorder()
    let (hostingView, window) = try Self.host(
      Host(document: try Self.makeDocument(), recorder: recorder, samplesPoints: true),
      receivesClicks: true
    )
    defer { Self.close(window) }
    try await Self.wait(in: hostingView, "The canvas did not report its fit") {
      recorder.zooms.isEmpty == false
    }

    // The centre of the canvas is the centre of the output.
    try Self.click(at: CGPoint(x: 150, y: 150), in: window)
    #expect(recorder.samples.count == 1)
    let sample = try #require(recorder.samples.first)
    #expect(abs(sample.x - 200) < 1e-9 && abs(sample.y - 100) < 1e-9)

    // A click above the letterboxed output samples nothing.
    try Self.click(at: CGPoint(x: 150, y: 280), in: window)
    #expect(recorder.samples.count == 1)
  }

  // MARK: - VoiceOver

  @Test
  func `The canvas takes a name for VoiceOver, which reads its zoom as its value`() async throws {
    let recorder = Recorder()
    let (hostingView, window) = try Self.host(
      Host(
        document: try Self.makeDocument(),
        recorder: recorder,
        areAnimationsEnabled: false,
        accessibilityLabel: "Photo"
      )
    )
    defer { Self.close(window) }
    try await Self.wait(in: hostingView, "The canvas did not report its fit") {
      recorder.zooms.isEmpty == false && recorder.proxy != nil
    }

    // The element VoiceOver reads is the AppKit view under the image.
    let element = try Self.view(at: CGPoint(x: 150, y: 150), in: window)
    #expect(element.isAccessibilityElement())
    #expect(element.accessibilityRole() == .image)
    #expect(element.accessibilityLabel() == "Photo")
    let fitted = try #require(recorder.zooms.last)
    #expect(element.accessibilityValue() as? String == fitted.percent.formatted(.percent))

    try #require(recorder.proxy).zoomIn()
    let zoomed = try #require(recorder.zooms.last)
    #expect(zoomed.percent == 2 * fitted.percent)
    #expect(element.accessibilityValue() as? String == zoomed.percent.formatted(.percent))
  }

  // MARK: - Helpers

  private static func makeDocument() throws -> ImageEditorDocument {
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
    return ImageEditorDocument(source: SourceImage(cgImage: try #require(context.makeImage())))
  }

  /// Shows `rootView` in a window whose content is 300 points square and
  /// that never shows on a screen: titled and never ordered in, or, with
  /// `receivesClicks`, borderless and ordered in far off every screen,
  /// because SwiftUI passes clicks on only in a window that is ordered in.
  private static func host<Content: View>(
    _ rootView: Content,
    receivesClicks: Bool = false
  ) throws -> (NSHostingView<Content>, NSWindow) {
    _ = NSApplication.shared
    let hostingView = NSHostingView(rootView: rootView)
    let size = CGSize(width: 300, height: 300)
    let window = if receivesClicks {
      NSWindow(
        contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
      )
    } else {
      NSWindow(
        contentRect: CGRect(origin: .zero, size: size),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
      )
    }
    window.isReleasedWhenClosed = false
    window.contentView = hostingView
    if receivesClicks {
      window.orderFrontRegardless()
    }
    try #require(hostingView.bounds.size == size, "The window's content is not 300 points square")
    return (hostingView, window)
  }

  private static func close(_ window: NSWindow) {
    window.orderOut(nil)
    window.contentView = nil
    window.close()
  }

  /// Lays `hostingView` out until `condition` holds, for five seconds at
  /// most.
  private static func wait(
    in hostingView: NSView,
    _ comment: Comment,
    sourceLocation: SourceLocation = #_sourceLocation,
    until condition: () -> Bool
  ) async throws {
    for _ in 0..<250 {
      hostingView.layoutSubtreeIfNeeded()
      if condition() {
        return
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record(comment, sourceLocation: sourceLocation)
    throw CancellationError()
  }

  /// The deepest view of `window` under `point` (window coordinates).
  private static func view(at point: CGPoint, in window: NSWindow) throws -> NSView {
    let contentView = try #require(window.contentView)
    let superview = try #require(contentView.superview)
    return try #require(contentView.hitTest(superview.convert(point, from: nil)))
  }

  /// Moves the pointer to `point` (window coordinates). AppKit sends a
  /// tracking area's moves only in the key window, and a window that never
  /// shows is never key, so the move goes to the view under the point, as
  /// its tracking area would send it.
  private static func movePointer(to point: CGPoint, in window: NSWindow) throws {
    let event = try #require(
      NSEvent.mouseEvent(
        with: .mouseMoved,
        location: point,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 0,
        pressure: 0
      )
    )
    try view(at: point, in: window).mouseMoved(with: event)
  }

  /// Clicks `window` at `point` (window coordinates), as the mouse would.
  private static func click(at point: CGPoint, in window: NSWindow) throws {
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      let event = try #require(
        NSEvent.mouseEvent(
          with: type,
          location: point,
          modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber,
          context: nil,
          eventNumber: 0,
          clickCount: 1,
          pressure: type == .leftMouseDown ? 1 : 0
        )
      )
      window.sendEvent(event)
    }
  }
}
#endif
