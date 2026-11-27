#if os(macOS)
import AppKit
@testable import BrightroomEngine
import BrightroomParametric
import CoreImage
import Metal
import SwiftUI
import Testing

@testable import BrightroomUI

/// `ImageEditorCanvas` on macOS, hosted the way an app hosts it: the AppKit
/// canvas is mounted, builds its render images, and shows the output fitted
/// after layout; it registers for commands in the environment's registry, and
/// an `ImageEditorCanvasReader`'s proxy sends it the zoom commands; its
/// reports reach the host outside SwiftUI updates, and its name reaches the
/// AppKit view VoiceOver reads. An editor's failure message replaces the
/// canvas's own. Presented pixels are not checked here; the shared drawing
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

  /// Shows the canvas, or not, under a registry of the test's.
  private struct RegistryHost: View {
    @State var document: ImageEditorDocument
    let registry: ImageEditorCanvasRegistry
    let showsCanvas: Bool

    var body: some View {
      ZStack {
        if showsCanvas {
          ImageEditorCanvas(document: $document)
            .editingTarget(nil)
        }
      }
      .environment(\.imageEditorCanvasRegistry, registry)
    }
  }

  /// The zooms a hosted canvas delivered, and whether one arrived while the
  /// test updated the hosting view.
  @MainActor
  private final class ZoomRecorder {
    var zooms: [ImageEditorCanvas.Zoom] = []
    var isUpdating = false
    private(set) var hasDeliveredDuringUpdate = false

    func record(_ zoom: ImageEditorCanvas.Zoom) {
      zooms.append(zoom)
      if isUpdating {
        hasDeliveredDuringUpdate = true
      }
    }
  }

  /// Shows the document it is given, so the test changes what the canvas
  /// shows by replacing the root view. The canvas writes nothing on macOS.
  private struct ZoomReportingHost: View {
    let document: ImageEditorDocument
    let recorder: ZoomRecorder

    var body: some View {
      ImageEditorCanvas(document: .constant(document))
        .editingTarget(nil)
        .onZoomChange { recorder.record($0) }
    }
  }

  /// Receives the proxy of an `ImageEditorCanvasReader` from inside a view.
  @MainActor
  private final class ProxyBox {
    var proxy: ImageEditorCanvasProxy?
  }

  /// A canvas inside a reader, which hands the test its proxy.
  private struct ReaderHost: View {
    let document: ImageEditorDocument
    let box: ProxyBox
    var loader: PreviewSourceLoader?
    var areAnimationsEnabled = true
    var recorder: ZoomRecorder?

    var body: some View {
      ImageEditorCanvasReader { canvas in
        ImageEditorCanvas(
          document: .constant(document),
          previewSourceLoader: loader,
          areAnimationsEnabled: areAnimationsEnabled
        )
        .editingTarget(nil)
        .onZoomChange { recorder?.record($0) }
        .onAppear { box.proxy = canvas }
      }
    }
  }

  /// Two canvases under one reader, the second shown or not.
  private struct TwoCanvasHost: View {
    let first: ImageEditorDocument
    let second: ImageEditorDocument
    let showsSecond: Bool
    let box: ProxyBox

    var body: some View {
      ImageEditorCanvasReader { canvas in
        VStack(spacing: 0) {
          ImageEditorCanvas(document: .constant(first), areAnimationsEnabled: false)
            .editingTarget(nil)
          if showsSecond {
            ImageEditorCanvas(document: .constant(second), areAnimationsEnabled: false)
              .editingTarget(nil)
          }
        }
        .onAppear { box.proxy = canvas }
      }
    }
  }

  /// A canvas named `label` for VoiceOver, or left unnamed. Either way it is
  /// the same view, so a change of label updates the mounted canvas.
  private struct LabelHost: View {
    let document: ImageEditorDocument
    let label: String?

    var body: some View {
      let canvas = ImageEditorCanvas(document: .constant(document))
        .editingTarget(nil)
      guard let label else {
        return canvas
      }
      return canvas.canvasAccessibilityLabel(label)
    }
  }

  @Test
  func `The canvas mounts the AppKit view and shows the output fitted`() async throws {
    let (hostingView, window) = Self.host(Host(document: try Self.makeDocument()))
    defer { Self.close(window) }

    // A placeholder in place of the AppKit canvas fails here.
    let canvas = try await Self.drawnCanvas(in: hostingView)
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

    // The canvas anchors its drawable at the top left (`contentsGravity`),
    // so a frame drawn before a resize stays there instead of being
    // stretched. Core Animation would anchor it at the bottom left if the
    // layer's contents counted as flipped; the picture itself is never
    // turned over, and `CanvasOutputRenderTests` checks its orientation.
    // That count runs up the layer's superlayers, which it gets when AppKit
    // next commits the views to Core Animation. The canvas can draw its
    // first frame before that, so wait until the layer is in the window's
    // layer tree.
    let metalLayer = try #require(canvasView.layer as? CAMetalLayer)
    let hostLayer = try #require(hostingView.layer, "The hosting view is not layer-backed")
    var isInLayerTree = false
    for _ in 0..<250 {
      isInLayerTree = sequence(first: metalLayer as CALayer, next: \.superlayer)
        .contains { $0 === hostLayer }
      if isInLayerTree {
        break
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    try #require(isInLayerTree, "The Metal layer did not join the window's layer tree")
    #expect(metalLayer.contentsAreFlipped() == false)
  }

  @Test
  func `The canvas registers in the environment's registry and leaves it when dismantled`() async throws {
    let document = try Self.makeDocument()
    let registry = ImageEditorCanvasRegistry()
    let (hostingView, window) = Self.host(
      RegistryHost(document: document, registry: registry, showsCanvas: true)
    )
    defer { Self.close(window) }

    let canvas = try await Self.drawnCanvas(in: hostingView)
    let mounted = try #require(canvas)
    #expect(registry.canvasView === mounted)

    // The test holds the canvas, so only leaving the registry removes it.
    hostingView.rootView = RegistryHost(document: document, registry: registry, showsCanvas: false)
    for _ in 0..<250 where registry.canvasView != nil {
      hostingView.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(registry.canvasView == nil)
    #expect(mounted.displayLink.isScheduled == false)
  }

  @Test
  func `A zoom reported while SwiftUI updates the canvas arrives on the next turn`() async throws {
    let recorder = ZoomRecorder()
    var document = try Self.makeDocument()
    let (hostingView, window) = Self.host(
      ZoomReportingHost(document: document, recorder: recorder)
    )
    defer { Self.close(window) }
    let drawn = try await Self.drawnCanvas(in: hostingView)
    let canvas = try #require(drawn)

    // The layout that drew the first frame reported the fit.
    for _ in 0..<250 where recorder.zooms.isEmpty {
      try await Task.sleep(for: .milliseconds(20))
    }
    let fitted = try #require(recorder.zooms.last)
    #expect(fitted.isFitted)

    // A square crop changes the output size, so the update that shows it
    // fits the new output at once. The zoom that reports waits for the next
    // turn.
    document.feature.crop = CropFeature(rect: CGRect(x: 0, y: 0, width: 200, height: 200))
    recorder.isUpdating = true
    hostingView.rootView = ZoomReportingHost(document: document, recorder: recorder)
    hostingView.layoutSubtreeIfNeeded()
    recorder.isUpdating = false
    try #require(
      canvas.outputGeometry?.outputSize == CGSize(width: 200, height: 200),
      "The update did not reach the canvas"
    )
    #expect(recorder.hasDeliveredDuringUpdate == false)

    for _ in 0..<250 where recorder.zooms.last == fitted {
      try await Task.sleep(for: .milliseconds(20))
    }
    let squareFit = try #require(recorder.zooms.last)
    #expect(squareFit.isFitted)
    #expect(squareFit.fitScale > fitted.fitScale)
  }

  @Test
  func `Reports made while SwiftUI inputs apply arrive on the next turn, and an equal one not again`() async throws {
    let canvas = Self.makeCanvas()
    defer { canvas.invalidate() }
    let coordinator = EditingCanvasRepresentable.Coordinator()
    var zooms: [ImageEditorCanvas.Zoom] = []
    var pointers: [CGPoint?] = []
    coordinator.bindReportHandlers(
      to: canvas,
      onZoomChange: { zooms.append($0) },
      onPointerChange: { pointers.append($0) }
    )
    let fitted = ImageEditorCanvas.Zoom(
      scale: 1,
      fitScale: 1,
      maximumScale: 8,
      displayScale: 2
    )
    let zoomed = ImageEditorCanvas.Zoom(
      scale: 2,
      fitScale: 1,
      maximumScale: 8,
      displayScale: 2
    )

    // Only the latest of each waits, even when the latest is no pixel.
    coordinator.applySwiftUIInputs {
      coordinator.deliverZoom(fitted)
      coordinator.deliverZoom(zoomed)
      coordinator.deliverPointer(CGPoint(x: 3, y: 4))
      coordinator.deliverPointer(nil)
    }
    #expect(zooms.isEmpty)
    #expect(pointers.isEmpty)
    for _ in 0..<250 where zooms.isEmpty || pointers.isEmpty {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(zooms == [zoomed])
    #expect(pointers == [nil])

    // Outside an update a report arrives at once, and an equal one is dropped.
    coordinator.deliverZoom(zoomed)
    coordinator.deliverZoom(fitted)
    coordinator.deliverPointer(nil)
    coordinator.deliverPointer(CGPoint(x: 5, y: 6))
    #expect(zooms == [zoomed, fitted])
    #expect(pointers == [nil, CGPoint(x: 5, y: 6)])

    // The canvas's own reports go through the coordinator.
    canvas.onZoomChange?(zoomed)
    #expect(zooms == [zoomed, fitted, zoomed])
  }

  @Test
  func `A zoom reported while the canvas lays out arrives on the next turn, and a command's at once`() async throws {
    let canvas = Self.makeCanvas()
    let window = Self.makeWindow(containing: canvas)
    defer {
      canvas.invalidate()
      window.close()
    }
    let coordinator = EditingCanvasRepresentable.Coordinator()
    var zooms: [ImageEditorCanvas.Zoom] = []
    coordinator.bindReportHandlers(
      to: canvas,
      onZoomChange: { zooms.append($0) },
      onPointerChange: { _ in }
    )

    // Layout can run inside a SwiftUI update, so what the canvas reports
    // while it lays out waits for the next turn, and only the latest.
    canvas.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
    canvas.layout()
    canvas.frame = CGRect(x: 0, y: 0, width: 200, height: 300)
    canvas.layout()
    #expect(zooms.isEmpty)
    for _ in 0..<250 where zooms.isEmpty {
      try await Task.sleep(for: .milliseconds(20))
    }
    // The 400 x 200 output fits the 200 points of width at 0.5.
    #expect(zooms.count == 1)
    #expect(zooms.first?.isFitted == true)
    #expect(zooms.first?.fitScale == 0.5)

    // A command reports before it returns.
    canvas.areAnimationsEnabled = false
    canvas.zoomIn()
    #expect(zooms.count == 2)
    #expect(zooms.last?.scale == 1)
  }

  @Test
  func `An editor's failure message replaces the canvas's own when the image cannot be loaded`() async throws {
    let document = try Self.makeDocument()
    // A preparation that fails, as it does for pixels that cannot be decoded.
    let loader = PreviewSourceLoader(source: document.source) { _ in nil }
    await loader.load()
    try #require(loader.phase == .failed)
    let message = "Das Bild konnte nicht geladen werden"

    // SwiftUI draws text without AppKit views, so the canvas is rendered
    // offscreen and compared with the failure view it should show.
    let shown = try Self.pixels(
      ImageEditorCanvas(
        document: .constant(document),
        displayedFeature: nil,
        previewSourceLoader: loader,
        failureMessage: message
      )
    )
    let own = try Self.pixels(
      ImageEditorCanvas(document: .constant(document), displayedFeature: nil, previewSourceLoader: loader)
    )
    let expectedShown = try Self.pixels(Self.failureView(message))
    let expectedOwn = try Self.pixels(Self.failureView("The image could not be loaded"))

    #expect(shown == expectedShown)
    #expect(own == expectedOwn)
    #expect(shown != own)
  }

  // MARK: - Reader and proxy

  @Test
  func `A reader's proxy sends the zoom commands to the canvas inside it`() async throws {
    let box = ProxyBox()
    let (hostingView, window) = Self.host(
      ReaderHost(document: try Self.makeDocument(), box: box, areAnimationsEnabled: false),
      ordersFront: false
    )
    defer { Self.close(window) }
    let drawn = try await Self.drawnCanvas(in: hostingView)
    let canvas = try #require(drawn)
    let proxy = try #require(box.proxy)
    let navigation = { canvas.navigation }
    let fit = navigation().fitScale
    let centre = navigation().position.center

    // Without animation each command applies at once, about the centre.
    proxy.zoomIn()
    #expect(abs(navigation().position.scale - 2 * fit) < 1e-9)
    proxy.zoomIn()
    #expect(abs(navigation().position.scale - 4 * fit) < 1e-9)
    proxy.zoomOut()
    #expect(abs(navigation().position.scale - 2 * fit) < 1e-9)
    #expect(abs(navigation().position.center.x - centre.x) < 1e-9)
    #expect(abs(navigation().position.center.y - centre.y) < 1e-9)
    proxy.zoomToFit()
    #expect(navigation().isFitted)
    proxy.zoom(toFraction: 1)
    #expect(abs(navigation().position.scale - navigation().scaleRange.upperBound) < 1e-9)
    proxy.zoom(toFraction: 0)
    #expect(navigation().isFitted)
    #expect(navigation().isMoving == false)
  }

  @Test(.enabled(if: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false))
  func `An animated zoom command starts a motion whose frames report the zoom`() async throws {
    let box = ProxyBox()
    let recorder = ZoomRecorder()
    let (hostingView, window) = Self.host(
      ReaderHost(document: try Self.makeDocument(), box: box, recorder: recorder),
      ordersFront: false
    )
    defer { Self.close(window) }
    let drawn = try await Self.drawnCanvas(in: hostingView)
    let canvas = try #require(drawn)
    for _ in 0..<250 where recorder.zooms.isEmpty {
      try await Task.sleep(for: .milliseconds(20))
    }
    let fitted = try #require(recorder.zooms.last)
    let proxy = try #require(box.proxy)

    proxy.zoomIn()
    #expect(recorder.zooms.count == 1, "The command only starts the motion.")
    #expect(canvas.navigation.isMoving)

    // The frames are ticked by hand, as the display link would tick them.
    for _ in 0..<250 where canvas.navigation.isMoving {
      canvas.drawViewportFrame()
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(canvas.navigation.isMoving == false)
    #expect(recorder.zooms.count > 1)
    #expect(abs((recorder.zooms.last?.scale ?? 0) - 2 * fitted.fitScale) < 1e-9)
  }

  @Test
  func `A proxy command does nothing while the canvas prepares its image`() async throws {
    let document = try Self.makeDocument()
    let (opening, gate) = AsyncStream<Void>.makeStream()
    defer { gate.finish() }
    // The preparation waits until the test finishes the gate.
    let loader = PreviewSourceLoader(source: document.source) { source in
      for await _ in opening {}
      return await PreviewSource.make(from: source)
    }
    let box = ProxyBox()
    let (hostingView, window) = Self.host(
      ReaderHost(document: document, box: box, loader: loader, areAnimationsEnabled: false),
      ordersFront: false
    )
    defer { Self.close(window) }

    for _ in 0..<250 where box.proxy == nil || loader.phase != .loading {
      hostingView.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(20))
    }
    let proxy = try #require(box.proxy)
    try #require(loader.phase == .loading)
    #expect(Self.findCanvas(in: hostingView) == nil)
    proxy.zoomIn()

    // The command reached no canvas, so the canvas mounts fitted.
    gate.finish()
    let drawn = try await Self.drawnCanvas(in: hostingView)
    let canvas = try #require(drawn)
    #expect(canvas.navigation.isFitted)
    proxy.zoomIn()
    #expect(abs(canvas.navigation.position.scale - 2 * canvas.navigation.fitScale) < 1e-9)
  }

  @Test
  func `Under one reader, commands go to the canvas mounted last that is still mounted`() async throws {
    let first = try Self.makeDocument()
    let second = try Self.makeDocument(size: CGSize(width: 200, height: 400))
    let box = ProxyBox()
    let (hostingView, window) = Self.host(
      TwoCanvasHost(first: first, second: second, showsSecond: false, box: box),
      ordersFront: false
    )
    defer { Self.close(window) }
    func canvas(of document: ImageEditorDocument) -> EditingCanvasView? {
      Self.findCanvases(in: hostingView).first { $0.source.imageSize == document.source.pixelSize }
    }
    let drawn = try await Self.drawnCanvas(in: hostingView)
    let firstCanvas = try #require(drawn)
    let proxy = try #require(box.proxy)
    proxy.zoomIn()
    #expect(firstCanvas.navigation.isFitted == false)
    proxy.zoomToFit()

    // The second canvas mounts after the first, so it takes the commands.
    hostingView.rootView = TwoCanvasHost(first: first, second: second, showsSecond: true, box: box)
    for _ in 0..<250 where canvas(of: second)?.surface.displayedViewport == nil {
      hostingView.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(20))
    }
    let secondCanvas = try #require(canvas(of: second))
    #expect(canvas(of: first) === firstCanvas)
    proxy.zoomIn()
    #expect(secondCanvas.navigation.isFitted == false)
    #expect(firstCanvas.navigation.isFitted)
    proxy.zoomToFit()

    // Once the second canvas is gone, the first takes them again.
    hostingView.rootView = TwoCanvasHost(first: first, second: second, showsSecond: false, box: box)
    for _ in 0..<250 where canvas(of: second) != nil {
      hostingView.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(20))
    }
    try #require(canvas(of: second) == nil)
    proxy.zoomIn()
    #expect(firstCanvas.navigation.isFitted == false)
  }

  // MARK: - VoiceOver

  @Test
  func `The canvas's name reaches the AppKit view VoiceOver reads, and follows the host`() async throws {
    let document = try Self.makeDocument()
    let (hostingView, window) = Self.host(LabelHost(document: document, label: "Photo"), ordersFront: false)
    defer { Self.close(window) }
    let drawn = try await Self.drawnCanvas(in: hostingView)
    let canvas = try #require(drawn)
    #expect(canvas.accessibilityLabel() == "Photo")

    hostingView.rootView = LabelHost(document: document, label: "Image")
    hostingView.layoutSubtreeIfNeeded()
    #expect(Self.findCanvas(in: hostingView) === canvas)
    #expect(canvas.accessibilityLabel() == "Image")

    hostingView.rootView = LabelHost(document: document, label: nil)
    hostingView.layoutSubtreeIfNeeded()
    #expect(Self.findCanvas(in: hostingView) === canvas)
    #expect(canvas.accessibilityLabel() == nil)
  }

  // MARK: - Helpers

  private static func makeDocument(size: CGSize = imageSize) throws -> ImageEditorDocument {
    ImageEditorDocument(source: SourceImage(cgImage: try makeImage(size: size)))
  }

  /// Hosts `rootView` in a window, as an app does: on screen, or, without
  /// `ordersFront`, in a window that is never ordered in and so never shows
  /// on a screen.
  private static func host<Content: View>(
    _ rootView: Content,
    ordersFront: Bool = true
  ) -> (NSHostingView<Content>, NSWindow) {
    _ = NSApplication.shared
    let hostingView = NSHostingView(rootView: rootView)
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 300, height: 300),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = hostingView
    if ordersFront {
      window.orderFrontRegardless()
    }
    return (hostingView, window)
  }

  private static func close(_ window: NSWindow) {
    window.orderOut(nil)
    window.contentView = nil
    window.close()
  }

  /// What the canvas shows when the image cannot be loaded, with `message`.
  private static func failureView(_ message: String) -> some View {
    ContentUnavailableView(message, systemImage: "exclamationmark.triangle")
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// The pixels SwiftUI renders offscreen for `view` in a 300-point square.
  private static func pixels(_ view: some View) throws -> Data {
    let renderer = ImageRenderer(content: view)
    renderer.proposedSize = ProposedViewSize(width: 300, height: 300)
    let image = try #require(renderer.cgImage)
    let data = try #require(image.dataProvider?.data)
    return data as Data
  }

  /// Lays out `hostingView` until its canvas has built its render images and
  /// drawn a frame, for five seconds at most; then whatever canvas is
  /// mounted, if any.
  private static func drawnCanvas(in hostingView: NSView) async throws -> EditingCanvasView? {
    for _ in 0..<250 {
      hostingView.layoutSubtreeIfNeeded()
      if let canvas = findCanvas(in: hostingView),
         canvas.surface.canvasView?.hasRenderImages == true,
         canvas.surface.displayedViewport != nil {
        return canvas
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    return findCanvas(in: hostingView)
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

  /// Every canvas mounted in the tree of `view`, depth first.
  private static func findCanvases(in view: NSView) -> [EditingCanvasView] {
    if let canvas = view as? EditingCanvasView {
      return [canvas]
    }
    return view.subviews.flatMap { findCanvases(in: $0) }
  }

  /// An AppKit canvas of its own, outside SwiftUI.
  private static func makeCanvas() -> EditingCanvasView {
    let image = CIImage(color: CIColor(red: 0.2, green: 0.5, blue: 0.8))
      .cropped(to: CGRect(origin: .zero, size: imageSize))
    return EditingCanvasView(
      source: EditingCanvasSource(editingSourceImage: image, imageSize: imageSize),
      feature: ImageEditorFeature(imageSize: imageSize)
    )
  }

  /// A window, not shown, whose content view holds `view` at the frame the
  /// test gives it.
  private static func makeWindow(containing view: NSView) -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 400, height: 400),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
    window.contentView?.addSubview(view)
    return window
  }

  private static func makeImage(size: CGSize = imageSize) throws -> CGImage {
    let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(
      data: nil,
      width: Int(size.width),
      height: Int(size.height),
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: sRGB,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(origin: .zero, size: size))
    return try #require(context.makeImage())
  }
}
#endif
