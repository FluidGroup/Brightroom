import BrightroomParametric
import CoreGraphics
import Testing

#if os(macOS)
import AppKit
import Metal
import SwiftUI
#endif

@testable import BrightroomEngine
@testable import BrightroomUI

/// What `ImageEditorCanvas` does with two of a host's inputs, where public
/// API cannot see it: a shared `PreviewSourceLoader` is the canvas's only
/// preparation of the image, and a loader of another image is ignored; a
/// displayed feature is what the canvas draws, with the member the editing
/// target edits taken from the document (`drawnFeature`).
///
/// The rule runs on both platforms; on macOS the canvas is hosted in a
/// window that never shows on a screen, and the AppKit canvas tells which
/// preview and which feature it was given.
@MainActor
@Suite(.serialized)
struct ImageEditorCanvasInputTests {

  private static let imageSize = CGSize(width: 400, height: 200)

  /// A feature that differs from `document`'s in its effects, its crop (a
  /// square) and its local blur (a stroke where the document has none, or
  /// none where it has one).
  private static func displayedFeature(over document: ImageEditorFeature) -> ImageEditorFeature {
    var feature = document
    feature.effects.exposure = ExposureFeature(ev: 1)
    feature.crop = CropFeature(rect: CGRect(x: 0, y: 0, width: 200, height: 200))
    feature.localBlur = document.localBlur == nil ? blur(at: 60) : nil
    return feature
  }

  /// A brush-painted blur with one horizontal stroke `y` pixels from the
  /// bottom.
  private static func blur(at y: CGFloat) -> LocalAdjustmentFeature<GaussianBlurFeature> {
    let stroke = BrushMask.Stroke(
      stampCenters: stride(from: 40, through: 360, by: 8).map { CGPoint(x: $0, y: y) },
      brush: BrushMask.Brush(diameter: 24, hardness: 0.5, opacity: 1)
    )
    return LocalAdjustmentFeature(mask: .brush(BrushMask(strokes: [stroke]))) {
      GaussianBlurFeature(radius: .proportional(20))
    }
  }

  // MARK: - The rule

  @Test
  func `Without a displayed feature, the canvas draws the document's feature for every target`() {
    var document = ImageEditorFeature(imageSize: Self.imageSize)
    document.localBlur = Self.blur(at: 100)
    for target in [ImageEditorCanvas.Target.crop, .localBlur, nil] {
      #expect(ImageEditorCanvas.drawnFeature(nil, over: document, editingTarget: target) == document)
    }
  }

  @Test
  func `A displayed feature is drawn whole without a target, and with the target's member taken from the document`() throws {
    var document = ImageEditorFeature(imageSize: Self.imageSize)
    document.localBlur = Self.blur(at: 100)
    let displayed = Self.displayedFeature(over: document)
    try #require(displayed.crop != document.crop && displayed.localBlur != document.localBlur)

    #expect(ImageEditorCanvas.drawnFeature(displayed, over: document, editingTarget: nil) == displayed)

    // The crop guide reloads from the drawn crop, so it is the document's.
    var drawnForCrop = displayed
    drawnForCrop.crop = document.crop
    #expect(ImageEditorCanvas.drawnFeature(displayed, over: document, editingTarget: .crop) == drawnForCrop)

    // Strokes are written into the document's blur, so they draw over it.
    var drawnForBlur = displayed
    drawnForBlur.localBlur = document.localBlur
    #expect(ImageEditorCanvas.drawnFeature(displayed, over: document, editingTarget: .localBlur) == drawnForBlur)
  }

  #if os(macOS)

  // MARK: - A shared loader

  /// Counts the preparations a loader's test seam runs.
  private actor Counter {
    private(set) var value = 0

    func increment() {
      value += 1
    }
  }

  /// The canvas over `loader`, with a second view that loads it too, as a
  /// host's histogram would.
  private struct SharingHost: View {
    let document: ImageEditorDocument
    let loader: PreviewSourceLoader

    var body: some View {
      ZStack {
        ImageEditorCanvas(document: .constant(document), previewSourceLoader: loader)
          .editingTarget(nil)
        Color.clear
          .task { await loader.load() }
      }
    }
  }

  @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
  func `The canvas shows a shared loader's preview, and the image is prepared once`() async throws {
    let document = try Self.makeDocument(size: Self.imageSize)
    let counter = Counter()
    let (opening, gate) = AsyncStream<Void>.makeStream()
    defer { gate.finish() }
    // The preparation waits until the test finishes the gate.
    let loader = PreviewSourceLoader(source: document.source) { source in
      await counter.increment()
      for await _ in opening {}
      return await PreviewSource.make(from: source)
    }
    let (hostingView, window) = Self.host(SharingHost(document: document, loader: loader))
    defer { Self.close(window) }

    // The canvas waits for the shared loader instead of preparing the image
    // itself: nothing is mounted while the loader loads.
    try await Self.wait(in: hostingView, "The views did not start the shared loader") {
      loader.phase == .loading
    }
    try await Self.settle(hostingView)
    #expect(Self.findCanvas(in: hostingView) == nil)

    gate.finish()
    let canvas = try #require(try await Self.drawnCanvas(in: hostingView))
    let previewSource = try #require(loader.previewSource)
    #expect(canvas.source.editingSourceImage === previewSource.image)
    #expect(canvas.source.imageSize == document.source.pixelSize)
    #expect(await counter.value == 1)
  }

  @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
  func `A loader of another image is ignored, and the canvas prepares the document's image itself`() async throws {
    let document = try Self.makeDocument(size: Self.imageSize)
    let other = try Self.makeDocument(size: CGSize(width: 200, height: 400))
    let counter = Counter()
    let loader = PreviewSourceLoader(source: other.source) { source in
      await counter.increment()
      return await PreviewSource.make(from: source)
    }
    let (hostingView, window) = Self.host(
      ImageEditorCanvas(document: .constant(document), previewSourceLoader: loader)
        .editingTarget(nil)
    )
    defer { Self.close(window) }

    let canvas = try #require(try await Self.drawnCanvas(in: hostingView))
    #expect(canvas.source.imageSize == Self.imageSize)
    #expect(loader.phase == .idle)
    #expect(await counter.value == 0)
  }

  // MARK: - A displayed feature

  /// Shows `document` with `displayed` in its place, for `target`, so the
  /// test changes them by replacing the root view.
  private struct DisplayingHost: View {
    let document: ImageEditorDocument
    let displayed: ImageEditorFeature?
    let target: ImageEditorCanvas.Target?

    var body: some View {
      ImageEditorCanvas(document: .constant(document))
        .displayedFeature(displayed)
        .editingTarget(target)
    }
  }

  @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
  func `The canvas draws the displayed feature in place of the document's, and the document's again without one`() async throws {
    let document = try Self.makeDocument(size: Self.imageSize)
    let displayed = Self.displayedFeature(over: document.feature)
    let (hostingView, window) = Self.host(
      DisplayingHost(document: document, displayed: displayed, target: nil)
    )
    defer { Self.close(window) }

    let canvas = try #require(try await Self.drawnCanvas(in: hostingView))
    #expect(canvas.feature == displayed)
    // The square crop is the output the canvas draws.
    #expect(canvas.outputGeometry?.outputSize == CGSize(width: 200, height: 200))
    canvas.drawViewportFrame()
    #expect(canvas.needsContentUpdate == false)

    hostingView.rootView = DisplayingHost(document: document, displayed: nil, target: nil)
    hostingView.layoutSubtreeIfNeeded()
    #expect(canvas.feature == document.feature)
    #expect(canvas.outputGeometry?.outputSize == Self.imageSize)
  }

  @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
  func `While the target is the crop or the local blur, the canvas draws that member from the document`() async throws {
    var document = try Self.makeDocument(size: Self.imageSize)
    document.feature.localBlur = Self.blur(at: 100)
    // Other effects, another crop, and no painted blur where the document
    // has one.
    let displayed = Self.displayedFeature(over: document.feature)
    try #require(displayed.localBlur == nil)
    let (hostingView, window) = Self.host(
      DisplayingHost(document: document, displayed: displayed, target: .crop)
    )
    defer { Self.close(window) }

    let canvas = try #require(try await Self.drawnCanvas(in: hostingView))
    #expect(canvas.feature.crop == document.feature.crop)
    #expect(canvas.feature.effects == displayed.effects)
    #expect(canvas.feature.localBlur == nil)

    // The document's crop is drawn as it changes, such as after an undo.
    document.feature.crop = CropFeature(rect: CGRect(x: 100, y: 0, width: 300, height: 200))
    hostingView.rootView = DisplayingHost(document: document, displayed: displayed, target: .crop)
    hostingView.layoutSubtreeIfNeeded()
    #expect(canvas.feature.crop == document.feature.crop)
    #expect(canvas.feature.effects == displayed.effects)

    hostingView.rootView = DisplayingHost(document: document, displayed: displayed, target: .localBlur)
    hostingView.layoutSubtreeIfNeeded()
    #expect(canvas.feature.localBlur == document.feature.localBlur)
    #expect(canvas.feature.crop == displayed.crop)
    #expect(canvas.feature.effects == displayed.effects)
  }

  // MARK: - Helpers

  private static func makeDocument(size: CGSize) throws -> ImageEditorDocument {
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
    return ImageEditorDocument(source: SourceImage(cgImage: try #require(context.makeImage())))
  }

  /// Shows `rootView` in a titled window, 300 points square, that is never
  /// ordered in, so it never shows on a screen.
  private static func host<Content: View>(_ rootView: Content) -> (NSHostingView<Content>, NSWindow) {
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

  /// Lays `hostingView` out for ten ticks, for changes with nothing to wait
  /// for.
  private static func settle(_ hostingView: NSView) async throws {
    for _ in 0..<10 {
      hostingView.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(20))
    }
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

  #endif
}
