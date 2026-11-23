#if os(macOS)

import AppKit
import Metal
import Observation
import SwiftUI
import Testing

@testable import BrightroomEngine
import BrightroomParametric
@testable import BrightroomUI

/// The macOS editor in a window that is never ordered on screen, hosted as an
/// app hosts it: in a navigation stack whose title, subtitle and toolbar the
/// window takes on, with a model the test hands in to drive it. A window that
/// takes clicks is ordered in far off every screen. Keys and clicks go to the
/// window in-process; nothing is posted to the system.
@MainActor
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct ImageEditorWindowTests {

  /// A host-side document that counts writes and Done, observed so the
  /// hosted editor follows it.
  @MainActor
  @Observable
  final class Host {
    var document: ImageEditorDocument
    private(set) var writes = 0
    private(set) var doneCalls = 0

    init(_ document: ImageEditorDocument) {
      self.document = document
    }

    var binding: Binding<ImageEditorDocument> {
      Binding(get: { self.document }, set: { self.document = $0; self.writes += 1 })
    }

    func done() {
      doneCalls += 1
    }
  }

  /// The editor as a navigation stack's root, titled by its host.
  struct EditorHost: View {
    let host: Host
    let loader: PreviewSourceLoader
    let options: ImageEditor.Options
    let model: ImageEditorModel
    let reducesMotion: Bool

    var body: some View {
      let stack = NavigationStack {
        ImageEditorContent(
          document: host.binding,
          previewSourceLoader: loader,
          options: options,
          localizedStrings: .init(),
          onDone: { host.done() },
          onCancel: nil,
          model: model
        )
        .navigationTitle(ImageEditorWindowTests.title)
        .navigationSubtitle(ImageEditorWindowTests.subtitle)
      }

      if reducesMotion {
        stack.environment(\._accessibilityReduceMotion, true)
      } else {
        stack
      }
    }
  }

  /// The editor hosted in a 1200 × 800 window.
  @MainActor
  final class Mounted: WindowFixture {

    let host: Host
    let loader: PreviewSourceLoader
    let model: ImageEditorModel
    let window: NSWindow
    let hostingView: NSView

    /// With `receivesClicks`, the window is ordered in far off every screen,
    /// so SwiftUI handles clicks in it. With `reducesMotion`, the editor sees
    /// Reduce Motion on, so a scroll the editor animates happens at once: an
    /// animated scroll needs a display, which a window off every screen does
    /// not have.
    init(
      _ document: ImageEditorDocument,
      loader: PreviewSourceLoader,
      options: ImageEditor.Options,
      receivesClicks: Bool = false,
      reducesMotion: Bool = false,
      solveGrayPoint: @escaping @Sendable (GrayPoint.Request) async -> Result<WhiteBalanceFeature?, GrayPoint.Rejection> = {
        _ in .success(nil)
      }
    ) {
      host = Host(document)
      self.loader = loader
      model = ImageEditorModel(
        documentAtStart: document,
        historyStep: .operation,
        analyze: { _ in nil },
        solveGrayPoint: solveGrayPoint
      )
      let hostingView = NSHostingView(
        rootView: EditorHost(
          host: host,
          loader: loader,
          options: options,
          model: model,
          reducesMotion: reducesMotion
        )
      )
      // The window takes the editor's title, subtitle and toolbar items.
      hostingView.sceneBridgingOptions = [.title, .toolbars]
      self.hostingView = hostingView
      window = Self.makeWindow(
        showing: hostingView,
        size: CGSize(width: 1200, height: 800),
        receivesClicks: receivesClicks
      )
    }

    /// The toolbar's buttons that are `NSButton`s: SwiftUI backs a
    /// borderless toolbar button with one, and draws the others itself.
    var toolbarBorderlessButtons: [NSButton] {
      (window.toolbar?.items ?? []).compactMap(\.view).flatMap { Self.all(NSButton.self, in: $0) }
    }
  }

  static let title = "gaku"
  static let subtitle = "2020-11-02 13:35 · 400 × 200"

  private static func document(
    _ change: (inout ImageEditorFeature) -> Void = { _ in }
  ) throws -> ImageEditorDocument {
    var document = ImageEditorDocument(
      source: SourceImage(cgImage: try DocumentTestFixtures.makeCGImage(width: 400, height: 200))
    )
    change(&document.feature)
    return document
  }

  /// Options with one preset, so the editor shows its filter strip.
  private static var options: ImageEditor.Options {
    var options = ImageEditor.Options()
    options.filters = [
      FilterFeature(name: "Warm", id: "warm", effects: [AnyImageEffect(BrightnessFeature(value: 0.1))])
    ]
    return options
  }

  /// The editor over a document whose image has already loaded, its feature
  /// changed by `change`.
  private static func mountLoaded(
    receivesClicks: Bool = false,
    editing change: (inout ImageEditorFeature) -> Void = { _ in },
    solveGrayPoint: @escaping @Sendable (GrayPoint.Request) async -> Result<WhiteBalanceFeature?, GrayPoint.Rejection> = {
      _ in .success(nil)
    }
  ) async throws -> Mounted {
    let document = try document(change)
    let loader = PreviewSourceLoader(source: document.source)
    await loader.load()
    try #require(loader.previewSource != nil, "The image did not load")
    return Mounted(
      document,
      loader: loader,
      options: options,
      receivesClicks: receivesClicks,
      solveGrayPoint: solveGrayPoint
    )
  }

  @Test func `Mounting writes nothing, the window shows the host's title, and the canvas fits the image`() async throws {
    let mounted = try await Self.mountLoaded()
    defer { mounted.close() }

    let canvas = try await mounted.drawnCanvas()
    #expect(canvas.navigation.isFitted)
    #expect(mounted.model.canvasRegistry.canvasView === canvas)
    try await mounted.wait(
      until: { mounted.window.title == Self.title && mounted.window.subtitle == Self.subtitle },
      "The window does not show the host's title and subtitle"
    )

    // The fit the first layout reported reaches the model on the next turn.
    try await mounted.wait(
      until: { mounted.model.zoom != nil },
      "The canvas's zoom did not reach the model"
    )
    #expect(mounted.model.zoom?.isFitted == true)
    #expect(mounted.host.writes == 0)
  }

  @Test func `The filter strip appears once the image has loaded`() async throws {
    let document = try Self.document()
    let (opening, gate) = AsyncStream<Void>.makeStream()
    defer { gate.finish() }
    // The preparation waits until the test finishes the gate.
    let loader = PreviewSourceLoader(source: document.source) { source in
      for await _ in opening {}
      return await PreviewSource.make(from: source)
    }
    let mounted = Mounted(document, loader: loader, options: Self.options)
    defer { mounted.close() }

    try await mounted.wait(
      until: { loader.phase == .loading },
      "The editor did not start loading the image"
    )
    try await mounted.settle()
    #expect(mounted.filterStrip == nil)
    #expect(mounted.canvas == nil)

    gate.finish()
    _ = try await mounted.drawnCanvas()
    try await mounted.wait(
      until: { mounted.filterStrip != nil },
      "The filter strip did not appear after the load"
    )
    #expect(mounted.host.writes == 0)
  }

  @Test func `The filter strip takes the arrow keys once clicked, not when the window opens`() async throws {
    let mounted = try await Self.mountLoaded(receivesClicks: true)
    defer { mounted.close() }
    _ = try await mounted.drawnCanvas()
    try await mounted.wait(
      until: { mounted.filterStrip != nil },
      "The filter strip did not appear"
    )
    let strip = try #require(mounted.filterStrip)

    // As the window does when it first becomes key: the first view of its
    // key view loop takes the keyboard.
    mounted.window.selectKeyView(following: mounted.hostingView)
    try await mounted.settle()
    try mounted.press(.rightArrow)
    try await mounted.settle()
    #expect(mounted.host.writes == 0, "The arrow changed the filter before the strip was clicked.")

    // A click on the preset's tile, after the Original tile at the strip's
    // leading edge, selects it and gives the strip the keyboard.
    let frame = strip.convert(strip.bounds, to: nil)
    try mounted.click(at: CGPoint(x: frame.minX + 100, y: frame.midY))
    try await mounted.wait(
      until: { mounted.host.writes == 1 },
      "The click did not select the preset"
    )
    #expect(mounted.host.document.feature.effects.preset?.id == "warm")

    try mounted.press(.leftArrow)
    try await mounted.wait(
      until: { mounted.host.writes == 2 },
      "The arrow did not select the tile before the preset"
    )
    #expect(mounted.host.document.feature.effects.preset == nil)
  }

  @Test func `Hiding the filter strip, the histogram and the inspector keeps the canvas and writes nothing`() async throws {
    let mounted = try await Self.mountLoaded()
    defer { mounted.close() }
    let canvas = try await mounted.drawnCanvas()
    try await mounted.wait(
      until: { mounted.filterStrip != nil },
      "The filter strip did not appear"
    )
    let bounds = canvas.bounds

    // The canvas takes the strip's height.
    mounted.model.setFilterStripVisible(false)
    try await mounted.wait(
      until: { mounted.filterStrip == nil && canvas.bounds.height > bounds.height },
      "The canvas did not take the filter strip's place"
    )
    #expect(mounted.canvas === canvas)

    mounted.model.setHistogramVisible(false)
    try await mounted.settle()
    #expect(mounted.canvas === canvas)

    // Unanimated, so the inspector goes at once rather than on a later frame.
    withTransaction(\.disablesAnimations, true) {
      mounted.model.setInspectorPresented(false)
    }
    try await mounted.wait(
      until: { canvas.bounds.width > bounds.width },
      "The canvas did not take the inspector's place"
    )
    #expect(mounted.canvas === canvas)
    #expect(mounted.model.canvasRegistry.canvasView === canvas)
    #expect(mounted.host.writes == 0)
  }

  @Test func `Return is Done: it calls onDone and writes nothing`() async throws {
    let mounted = try await Self.mountLoaded()
    defer { mounted.close() }
    _ = try await mounted.drawnCanvas()
    // Done is a toolbar item.
    try await mounted.wait(
      until: { mounted.window.toolbar?.items.isEmpty == false },
      "The window has no toolbar items"
    )

    #expect(try mounted.pressKeyEquivalent("\r", keyCode: 36))
    #expect(mounted.host.doneCalls == 1)
    #expect(mounted.host.writes == 0)
  }

  @Test func `Done drops a gray point still solving, so nothing is written after onDone`() async throws {
    let solver = ImageEditorModelTests.GrayPointSolver()
    let mounted = try await Self.mountLoaded(solveGrayPoint: { await solver.solve($0) })
    defer { mounted.close() }
    _ = try await mounted.drawnCanvas()
    try await mounted.wait(
      until: { mounted.window.toolbar?.items.isEmpty == false },
      "The window has no toolbar items"
    )
    let previewSource = try #require(mounted.loader.previewSource)

    mounted.model.beginGrayPointSampling()
    mounted.model.sampleGrayPoint(
      atOutputPoint: CGPoint(x: 100, y: 50),
      previewSource: previewSource,
      rendering: .standard,
      in: mounted.host.binding
    )
    let solve = try #require(mounted.model.grayPointTask)
    try await mounted.wait(until: { solver.requests.count == 1 }, "The solve never started")

    #expect(try mounted.pressKeyEquivalent("\r", keyCode: 36))
    #expect(mounted.host.doneCalls == 1)
    #expect(mounted.model.grayPointSampling == .off)

    solver.answer(.success(WhiteBalanceFeature(temperature: 500)))
    await solve.value
    #expect(mounted.host.writes == 0)
  }

  @Test func `The zoom buttons take 24-point squares, and every toolbar item shows in the narrowest window`() async throws {
    let mounted = try await Self.mountLoaded()
    defer { mounted.close() }
    _ = try await mounted.drawnCanvas()
    let toolbar = try #require(mounted.window.toolbar)
    try await mounted.wait(
      until: { mounted.toolbarBorderlessButtons.count == 2 },
      "The toolbar does not show the zoom buttons"
    )

    for button in mounted.toolbarBorderlessButtons {
      #expect(button.frame.size == CGSize(width: 24, height: 24))
    }

    // The editor's minimum width beside the inspector.
    mounted.window.setContentSize(CGSize(width: 810, height: 464))
    try await mounted.settle()
    #expect(toolbar.visibleItems?.count == toolbar.items.count)
  }

  @Test func `Command-equals, Command-plus, Command-minus and Command-0 zoom the canvas`() async throws {
    let mounted = try await Self.mountLoaded()
    defer { mounted.close() }
    let canvas = try await mounted.drawnCanvas()
    try #require(canvas.navigation.isFitted)
    let fit = canvas.navigation.fitScale

    #expect(try mounted.pressKeyEquivalent("=", modifiers: .command, keyCode: 24))
    try await mounted.settleMotion(of: canvas)
    #expect(abs(canvas.navigation.position.scale - fit * 2) < 1e-6)

    #expect(try mounted.pressKeyEquivalent("+", modifiers: [.command, .shift], keyCode: 24))
    try await mounted.settleMotion(of: canvas)
    #expect(abs(canvas.navigation.position.scale - fit * 4) < 1e-6)

    #expect(try mounted.pressKeyEquivalent("-", modifiers: .command, keyCode: 27))
    try await mounted.settleMotion(of: canvas)
    #expect(abs(canvas.navigation.position.scale - fit * 2) < 1e-6)

    #expect(try mounted.pressKeyEquivalent("0", modifiers: .command, keyCode: 29))
    try await mounted.settleMotion(of: canvas)
    #expect(canvas.navigation.isFitted)
    #expect(mounted.model.zoom?.isFitted == true)
    #expect(mounted.host.writes == 0)
  }

  @Test func `At the fit the photo keeps 12 points from the image column's edges and 20 from the filter strip's tiles`() async throws {
    // A portrait image, so the photo fills the canvas's height inside the
    // margin.
    let document = ImageEditorDocument(
      source: SourceImage(cgImage: try DocumentTestFixtures.makeCGImage(width: 200, height: 400))
    )
    let loader = PreviewSourceLoader(source: document.source)
    await loader.load()
    try #require(loader.previewSource != nil, "The image did not load")
    // More presets than the strip shows, so it scrolls and shows its
    // scroller while scrollers are legacy.
    var options = ImageEditor.Options()
    options.filters = (0..<30).map {
      FilterFeature(name: "Preset \($0)", id: "preset-\($0)", effects: [AnyImageEffect(BrightnessFeature(value: 0.1))])
    }
    let mounted = Mounted(document, loader: loader, options: options, receivesClicks: true)
    defer { mounted.close() }
    let canvas = try await mounted.drawnCanvas()
    try await mounted.wait(
      until: { mounted.filterStrip != nil },
      "The filter strip did not appear"
    )
    let strip = try #require(mounted.filterStrip)

    // The photo, in the canvas's top-left coordinates.
    #expect(canvas.fitMargin == 12)
    let viewport = try #require(canvas.surface.displayedViewport)
    let outputSize = try #require(canvas.outputGeometry?.outputSize)
    let photo = CGRect(origin: .zero, size: outputSize).applying(viewport.contentToCanvasTransform)
    #expect(abs(photo.minY - 12) < 1e-6)
    #expect(abs(canvas.bounds.maxY - photo.maxY - 12) < 1e-6)
    #expect(photo.minX >= 12)
    #expect(canvas.bounds.maxX - photo.maxX >= 12)

    // The strip starts where the canvas ends: 80 points for its row of
    // tiles, which it shows whole, and under it the room a legacy scroller
    // takes. Window coordinates run up.
    let canvasFrame = canvas.convert(canvas.bounds, to: nil)
    let stripFrame = strip.convert(strip.bounds, to: nil)
    let scroller = NSScroller.preferredScrollerStyle == .legacy
      ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
      : 0
    #expect(abs(stripFrame.maxY - canvasFrame.minY) < 1e-6)
    #expect(abs(stripFrame.height - (80 + scroller)) < 1e-6)
    #expect(abs(strip.contentView.frame.height - 80) < 1e-6)

    // Clicks just outside and just inside the tiles find them where the
    // margins put them: Original 12 points from the strip's leading edge and
    // 8 below its top, and the first preset 8 points after Original, at 80.
    func click(_ x: CGFloat, belowTop y: CGFloat) throws {
      try mounted.click(at: CGPoint(x: stripFrame.minX + x, y: stripFrame.maxY - y))
    }
    try click(79, belowTop: 40)
    try await mounted.settle()
    #expect(mounted.host.writes == 0, "A click in the gap before the first preset selected it.")
    try click(81, belowTop: 40)
    try await mounted.wait(
      until: { mounted.host.writes == 1 },
      "A click just inside the first preset did not select it"
    )
    try click(42, belowTop: 7)
    try await mounted.settle()
    #expect(mounted.host.writes == 1, "A click above Original selected it.")
    try click(42, belowTop: 9)
    try await mounted.wait(
      until: { mounted.host.writes == 2 },
      "A click just inside Original did not select it"
    )
  }

  @Test func `When every tile shows, the filter strip keeps no room for a scroller, and its tiles keep 8 points from its top and 12 from its bottom`() async throws {
    let mounted = try await Self.mountLoaded(receivesClicks: true)
    defer { mounted.close() }
    let canvas = try await mounted.drawnCanvas()
    try await mounted.wait(
      until: { mounted.filterStrip != nil },
      "The filter strip did not appear"
    )
    try await mounted.settle()
    let strip = try #require(mounted.filterStrip)

    // Original and the one preset show whole, so a legacy scroller hides,
    // and the strip is the tiles' row alone, directly under the canvas.
    // Window coordinates run up.
    let canvasFrame = canvas.convert(canvas.bounds, to: nil)
    let stripFrame = strip.convert(strip.bounds, to: nil)
    #expect(abs(stripFrame.maxY - canvasFrame.minY) < 1e-6)
    #expect(abs(stripFrame.height - 80) < 1e-6)

    // The preset stands 8 points after Original, from 80 to 140 along the
    // strip. Clicks just outside its top and bottom miss it; one just inside
    // its top selects it.
    func click(belowTop y: CGFloat) throws {
      try mounted.click(at: CGPoint(x: stripFrame.minX + 110, y: stripFrame.maxY - y))
    }
    try click(belowTop: 7)
    try click(belowTop: 69)
    try await mounted.settle()
    #expect(mounted.host.writes == 0, "A click outside the preset's row selected it.")
    try click(belowTop: 9)
    try await mounted.wait(
      until: { mounted.host.writes == 1 },
      "A click just inside the preset did not select it"
    )
  }

  @Test func `A click leaves the filter strip still unless its tile is cut off, and other selections centre their tile`() async throws {
    let document = try Self.document()
    let loader = PreviewSourceLoader(source: document.source)
    await loader.load()
    try #require(loader.previewSource != nil, "The image did not load")
    var options = ImageEditor.Options()
    options.filters = (0..<30).map {
      FilterFeature(name: "Preset \($0)", id: "preset-\($0)", effects: [AnyImageEffect(BrightnessFeature(value: 0.1))])
    }
    let mounted = Mounted(document, loader: loader, options: options, receivesClicks: true, reducesMotion: true)
    defer { mounted.close() }
    let canvas = try await mounted.drawnCanvas()
    try await mounted.wait(
      until: { mounted.filterStrip != nil },
      "The filter strip did not appear"
    )
    let strip = try #require(mounted.filterStrip)
    let stripFrame = strip.convert(strip.bounds, to: nil)
    // The strip's scroll view runs on under the inspector, which insets its
    // content, so the tiles show across the image column: the canvas's
    // width.
    let width = canvas.bounds.width

    // Along the scrolled content, which starts after the 12-point end
    // padding: Original at 0, then preset i 8 points after it, from
    // 68 + 60i to 128 + 60i. The clip view's origin is the scroll offset,
    // -12 at the start.
    var offset: CGFloat {
      strip.contentView.bounds.minX
    }
    func centredOffset(ofPreset index: Int) -> CGFloat {
      68 + 60 * CGFloat(index) + 30 - width / 2
    }
    func click(atStripX x: CGFloat) throws {
      try mounted.click(at: CGPoint(x: stripFrame.minX + x, y: stripFrame.maxY - 40))
    }
    try await mounted.wait(until: { offset == -12 }, "The strip does not start at its end padding")

    // A change from outside the strip, such as an undo, centres its preset.
    mounted.host.document.feature.effects.preset = options.filters[10]
    try await mounted.wait(
      until: { abs(offset - centredOffset(ofPreset: 10)) < 0.5 },
      "The host's selection was not centred"
    )
    let centred = offset

    // A click on a preset that shows whole leaves the strip where it is.
    try click(atStripX: 68 + 60 * 6 + 30 - offset)
    try await mounted.wait(until: { mounted.host.writes == 1 }, "The click did not select preset 6")
    #expect(mounted.host.document.feature.effects.preset?.id == "preset-6")
    try await mounted.settle()
    #expect(offset == centred)

    // The strip's trailing edge cuts preset 17, most of which shows: a click
    // scrolls it in until its end stands 12 points inside the edge.
    let trailingCutStart = 68 + 60 * 17 - offset
    try #require(
      trailingCutStart < width - 20 && trailingCutStart + 60 > width,
      "The trailing edge does not cut preset 17 at a width of \(width)"
    )
    try click(atStripX: (trailingCutStart + width) / 2)
    try await mounted.wait(until: { mounted.host.writes == 2 }, "The click did not select preset 17")
    #expect(mounted.host.document.feature.effects.preset?.id == "preset-17")
    let trailingRevealed = 128 + 60 * 17 - (width - 12)
    try await mounted.wait(
      until: { abs(offset - trailingRevealed) < 0.5 },
      "Preset 17 did not scroll just into view"
    )

    // The arrow keys centre the preset they select.
    try mounted.press(.leftArrow)
    try await mounted.wait(until: { mounted.host.writes == 3 }, "The arrow did not select preset 16")
    try await mounted.wait(
      until: { abs(offset - centredOffset(ofPreset: 16)) < 0.5 },
      "The arrow's selection was not centred"
    )

    // The leading edge now cuts preset 9, most of which shows: a click
    // scrolls it in until it starts 12 points inside the edge.
    let leadingCutStart = 68 + 60 * 9 - offset
    try #require(
      leadingCutStart < 0 && leadingCutStart + 60 > 20,
      "The leading edge does not cut preset 9 at a width of \(width)"
    )
    try click(atStripX: (leadingCutStart + 60) / 2)
    try await mounted.wait(until: { mounted.host.writes == 4 }, "The click did not select preset 9")
    let leadingRevealed: CGFloat = 68 + 60 * 9 - 12
    try await mounted.wait(
      until: { abs(offset - leadingRevealed) < 0.5 },
      "Preset 9 did not scroll just into view"
    )
    try await mounted.settle()
    #expect(abs(offset - leadingRevealed) < 0.5)
  }

  @Test func `Zoomed in, a click gives the photo the keyboard, the arrows pan it, and VoiceOver reads its name and zoom`() async throws {
    let mounted = try await Self.mountLoaded(receivesClicks: true)
    defer { mounted.close() }
    let canvas = try await mounted.drawnCanvas()
    #expect(canvas.accessibilityLabel() == ImageEditor.LocalizedStrings().photo)

    mounted.model.zoomIn()
    try await mounted.settleMotion(of: canvas)
    try await mounted.wait(
      until: { mounted.model.zoom?.isFitted == false },
      "The zoom did not reach the model"
    )
    let zoom = try #require(mounted.model.zoom)
    #expect(canvas.accessibilityValue() as? String == zoom.percent.formatted(.percent))

    let zoomed = canvas.navigation.position
    try mounted.click(at: canvas.convert(CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY), to: nil))
    try await mounted.wait(
      until: { mounted.window.firstResponder === canvas },
      "A click on the zoomed photo did not give it the keyboard"
    )

    // The Right arrow pans a tenth of the canvas.
    try mounted.press(.rightArrow)
    let step = canvas.bounds.width / 10 / zoomed.scale
    #expect(abs(canvas.navigation.position.center.x - (zoomed.center.x + step)) < 1e-6)
    #expect(canvas.navigation.position.center.y == zoomed.center.y)
    #expect(mounted.host.writes == 0)
  }

  @Test func `With Full Keyboard Access, the zoomed photo's focus ring stays inside the image column`() async throws {
    let mounted = try await Self.mountLoaded()
    defer { mounted.close() }
    let canvas = try await mounted.drawnCanvas()
    let exposure = try await mounted.slider("image-editor.adjust.exposure")
    try await mounted.wait(
      until: { mounted.filterStrip != nil },
      "The filter strip did not appear"
    )
    let strip = try #require(mounted.filterStrip)
    let inspector = try #require(exposure.enclosingScrollView, "The inspector's slider is not in a scroll view")
    canvas.isFullKeyboardAccessEnabled = { true }
    #expect(canvas.focusRingMaskBounds == .zero, "The fitted photo has a focus ring.")

    mounted.model.zoomIn()
    try await mounted.settleMotion(of: canvas)
    #expect(canvas.canBecomeKeyView)

    // AppKit draws the ring outside the mask, which stands 4 points inside
    // the canvas: the image column, which ends at the toolbar, the window's
    // leading edge, the inspector and the filter strip. Window coordinates
    // run up.
    let column = canvas.convert(canvas.bounds, to: nil)
    #expect(canvas.convert(canvas.focusRingMaskBounds, to: nil) == column.insetBy(dx: 4, dy: 4))
    #expect(mounted.window.contentLayoutRect.contains(column))
    #expect(column.minX == 0)
    #expect(column.maxX <= inspector.convert(inspector.bounds, to: nil).minX)
    #expect(column.minY >= strip.convert(strip.bounds, to: nil).maxY - 1e-6)
    #expect(mounted.host.writes == 0)
  }

  @Test func `Control-Command-I hides and shows the adjustments, also after the inspector was collapsed`() async throws {
    let mounted = try await Self.mountLoaded()
    defer { mounted.close() }
    _ = try await mounted.drawnCanvas()
    #expect(mounted.model.selectedTool == .adjust)

    // The inspector reports its presentation while it animates, so each
    // press waits that out.
    #expect(try mounted.pressKeyEquivalent("i", modifiers: [.control, .command], keyCode: 34))
    #expect(mounted.model.selectedTool == nil)
    try await mounted.settleInspector()
    #expect(mounted.model.selectedTool == nil)

    #expect(try mounted.pressKeyEquivalent("i", modifiers: [.control, .command], keyCode: 34))
    #expect(mounted.model.selectedTool == .adjust)
    try await mounted.settleInspector()
    #expect(mounted.model.selectedTool == .adjust)

    // As dragging the inspector closed reports it.
    mounted.model.setInspectorPresented(false)
    try await mounted.settleInspector()
    #expect(try mounted.pressKeyEquivalent("i", modifiers: [.control, .command], keyCode: 34))
    #expect(mounted.model.selectedTool == .adjust)
    try await mounted.settleInspector()
    #expect(mounted.model.selectedTool == .adjust)
    #expect(mounted.host.writes == 0)
  }

  @Test(.enabled(if: hasActiveDisplay(), "The inspector's animation needs a display that can draw"))
  func `Control-Command-I during a grading wheel's drag writes what the drag shows once, and the next grading change writes`() async throws {
    let tint = ColorGradingFeature.Correction(hue: 30, saturation: 40)
    let mounted = try await Self.mountLoaded(receivesClicks: true, editing: {
      $0.effects.colorGrading = ColorGradingFeature(shadows: tint)
    })
    defer { mounted.close() }
    _ = try await mounted.drawnCanvas()

    // The cards above Color Grading close, so its wheels show in the window.
    mounted.model.toggleExpansion(of: .whiteBalance)
    mounted.model.toggleExpansion(of: .basic)
    try await mounted.wait(
      until: { mounted.wheelKeyboards.count == 3 },
      "The 3-Way wheels do not show"
    )
    let wheel = mounted.wheelKeyboards[0]
    let frame = wheel.convert(wheel.bounds, to: nil)
    try #require(mounted.window.contentLayoutRect.contains(frame), "The shadows wheel is out of the window")

    // The press grabs the shadows puck, and the drag moves it 10 points.
    let angle = tint.hue / 180 * .pi
    let distance = tint.saturation / 100 * frame.width / 2
    let puck = CGPoint(x: frame.midX + cos(angle) * distance, y: frame.midY - sin(angle) * distance)
    let dragged = CGPoint(x: puck.x + 10, y: puck.y)
    try mounted.mouse(.leftMouseDown, at: puck)
    try mounted.mouse(.leftMouseDragged, at: dragged)
    try await mounted.wait(
      until: { mounted.model.displayedFeature(of: mounted.host.document).effects.colorGrading?.shadows != tint },
      "The drag shows nothing"
    )
    let shown = mounted.model.displayedFeature(of: mounted.host.document).effects.colorGrading
    #expect(mounted.host.writes == 0)

    // The inspector hides before the mouse-up, which then ends nothing.
    #expect(try mounted.pressKeyEquivalent("i", modifiers: [.control, .command], keyCode: 34))
    try await mounted.wait(
      until: { mounted.host.writes == 1 },
      "The drag the inspector cut short was not written"
    )
    try await mounted.settleInspector()
    try mounted.mouse(.leftMouseUp, at: dragged)
    try await mounted.settle()
    #expect(mounted.host.writes == 1)
    #expect(mounted.host.document.feature.effects.colorGrading == shown)

    let next = ColorGradingFeature(shadows: .init(hue: 30, saturation: 40, luminance: 1))
    mounted.model.commit(.colorGrading(next), to: mounted.host.binding)
    #expect(mounted.host.writes == 2)
    #expect(mounted.host.document.feature.effects.colorGrading == next)
  }

  @Test func `A host's write is shown, and nothing is written back`() async throws {
    let mounted = try await Self.mountLoaded()
    defer { mounted.close() }
    let canvas = try await mounted.drawnCanvas()

    // The host's own change, as an undo would make it.
    mounted.host.document.feature.effects.exposure = ExposureFeature(ev: 0.5)
    let written = mounted.host.document.feature
    try await mounted.wait(
      until: { canvas.feature == written },
      "The canvas did not receive the host's write"
    )
    // A change that keeps the crop is built on the next frame.
    canvas.drawViewportFrame()
    #expect(canvas.needsContentUpdate == false)
    #expect(canvas.surface.canvasView?.hasRenderImages == true)
    #expect(mounted.model.displayedFeature(of: mounted.host.document) == written)
    #expect(mounted.host.writes == 0)
  }
}

#endif
