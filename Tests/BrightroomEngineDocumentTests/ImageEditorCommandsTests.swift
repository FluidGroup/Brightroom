#if os(macOS)

import AppKit
import Metal
import Observation
import SwiftUI
import Testing

@testable import BrightroomEngine
import BrightroomParametric
@testable import BrightroomUI

/// What the macOS editor publishes for `ImageEditorCommands`: each item's
/// enabled and checked state against the editor's own controls, and the
/// writes its actions make. Then, in a window that is never ordered on
/// screen, a reader of the scene's focused values beside the editor, as the
/// commands read them: it finds the editor whatever has focus, follows it,
/// drives it, and loses it when the editor goes. Keys and clicks go to the
/// window in-process; nothing is posted to the system.
@MainActor
struct ImageEditorCommandsTests {

  typealias Fixtures = DocumentTestFixtures
  typealias Editor = ImageEditorCommands.Editor

  private static let preset = FilterFeature(
    name: "Warm",
    id: "warm",
    effects: [AnyImageEffect(BrightnessFeature(value: 0.1))]
  )

  /// Options with one preset, so the editor shows its filter strip.
  private static var options: ImageEditor.Options {
    var options = ImageEditor.Options()
    options.filters = [preset]
    return options
  }

  /// A feature without values, over the whole image.
  private static var plain: ImageEditorFeature {
    ImageEditorFeature(imageSize: Fixtures.rotatedJPEGSize)
  }

  /// `plain` with an exposure, the preset and a painted blur.
  private static var edited: ImageEditorFeature {
    let stroke = BrushMask.Stroke(
      stampCenters: [CGPoint(x: 10, y: 20)],
      brush: .init(diameter: 8, hardness: 1, opacity: 1)
    )
    var feature = plain
    feature.effects.exposure = ExposureFeature(ev: 0.5)
    feature.effects.preset = preset
    feature.localBlur = LocalAdjustmentFeature(mask: .brush(BrushMask(strokes: [stroke]))) {
      GaussianBlurFeature(radius: .absolute(4))
    }
    return feature
  }

  /// A host of a document of `feature`, the model of an editor that opens
  /// it, and the actions the editor's commands take on it.
  private func makeEditor(
    _ feature: ImageEditorFeature = Self.plain,
    options: ImageEditor.Options = Self.options
  ) throws -> (host: ImageEditorModelTests.Host, model: ImageEditorModel, actions: Editor.Actions) {
    let host = ImageEditorModelTests.Host(try Fixtures.makeDocument(feature: feature))
    let model = ImageEditorModel(
      documentAtStart: host.document,
      historyStep: .operation,
      analyze: { _ in nil }
    )
    return (host, model, Editor.Actions(model: model, document: host.binding, options: options))
  }

  // MARK: - The published value

  @Test func `Each item is enabled when its control in the editor is`() throws {
    // Without an edit the Image menu is disabled, and Show Original is
    // enabled once the image has loaded.
    let (plainHost, plainModel, plainActions) = try makeEditor()
    let unloaded = Editor(actions: plainActions, document: plainHost.document, isLoaded: false)
    let loaded = Editor(actions: plainActions, document: plainHost.document, isLoaded: true)
    #expect(unloaded.canShowOriginal == false)
    #expect(loaded.canShowOriginal)
    for editor in [unloaded, loaded] {
      #expect(editor.canRevert == false)
      #expect(editor.canResetAdjustments == false)
      #expect(editor.canRemoveFilter == false)
      #expect(editor.canRemoveLocalBlur == false)
    }

    // A slider's live value counts for Revert and Reset, as the toolbar and
    // the inspector count it.
    plainModel.preview(.slider(.exposure, 40), in: plainHost.binding)
    let dragging = Editor(actions: plainActions, document: plainHost.document, isLoaded: true)
    #expect(dragging.canRevert)
    #expect(dragging.canResetAdjustments)
    #expect(dragging.canRemoveFilter == false)

    let (host, model, actions) = try makeEditor(Self.edited)
    let editedLoaded = Editor(actions: actions, document: host.document, isLoaded: true)
    #expect(editedLoaded.canRevert)
    #expect(editedLoaded.canResetAdjustments)
    #expect(editedLoaded.canRemoveFilter)
    #expect(editedLoaded.canRemoveLocalBlur)

    // Each matches its twin: Revert to Original in the toolbar, Reset in the
    // inspector's footer, and the removals in the More menu.
    for isLoaded in [false, true] {
      let editor = Editor(actions: actions, document: host.document, isLoaded: isLoaded)
      #expect(editor.canRevert == model.canRevert(host.document, options: Self.options, isLoaded: isLoaded))
      #expect(editor.canResetAdjustments == (isLoaded && model.canResetAdjustments(in: host.document)))
      #expect(editor.canRemoveFilter == model.canRemoveFilter(host.document, isLoaded: isLoaded))
      #expect(editor.canRemoveLocalBlur == model.canRemoveLocalBlur(host.document, isLoaded: isLoaded))
    }
  }

  @Test func `Zoom In is enabled below the largest zoom, Zoom Out and Zoom to Fit above the fit`() throws {
    let (host, model, actions) = try makeEditor()
    func editor() -> Editor {
      Editor(actions: actions, document: host.document, isLoaded: true)
    }

    // Before the canvas reports its zoom, as the toolbar's buttons wait.
    #expect(editor().canZoomIn == false)
    #expect(editor().canZoomOut == false)

    model.canvasDidReportZoom(.init(scale: 1, fitScale: 1, maximumScale: 8, backingScaleFactor: 2))
    #expect(editor().canZoomIn)
    #expect(editor().canZoomOut == false)

    model.canvasDidReportZoom(.init(scale: 2, fitScale: 1, maximumScale: 8, backingScaleFactor: 2))
    #expect(editor().canZoomIn)
    #expect(editor().canZoomOut)

    model.canvasDidReportZoom(.init(scale: 8, fitScale: 1, maximumScale: 8, backingScaleFactor: 2))
    #expect(editor().canZoomIn == false)
    #expect(editor().canZoomOut)
  }

  @Test func `The checkmarks follow Show Original, the histogram and the filter strip, and turning them writes nothing`() throws {
    let (host, model, actions) = try makeEditor()
    func editor() -> Editor {
      Editor(actions: actions, document: host.document, isLoaded: true)
    }
    #expect(editor().showsOriginal == false)
    #expect(editor().isHistogramVisible)
    #expect(editor().hasFilters)
    #expect(editor().isFilterStripVisible)

    actions.setComparing(true)
    #expect(model.isComparing)
    #expect(editor().showsOriginal)
    actions.setComparing(false)
    #expect(editor().showsOriginal == false)

    // Holding M shows the original, so the item shows it on.
    model.setHoldingOriginal(true)
    #expect(editor().showsOriginal)
    model.setHoldingOriginal(false)

    actions.setHistogramVisible(false)
    #expect(model.isHistogramVisible == false)
    #expect(editor().isHistogramVisible == false)

    actions.setFilterStripVisible(false)
    #expect(model.isFilterStripVisible == false)
    #expect(editor().isFilterStripVisible == false)
    #expect(host.writes == 0)

    // Without presets there is no strip: Show Filters is off and disabled.
    let (bareHost, _, bareActions) = try makeEditor(options: .init())
    let bare = Editor(actions: bareActions, document: bareHost.document, isLoaded: true)
    #expect(bare.hasFilters == false)
    #expect(bare.isFilterStripVisible == false)
  }

  @Test func `The Image menu's actions write as the editor's controls do`() throws {
    let opened = Self.edited
    let (host, model, actions) = try makeEditor(opened)

    actions.removeFilter()
    #expect(host.writes == 1)
    #expect(host.document.feature.effects.preset == nil)
    #expect(host.document.feature.localBlur == opened.localBlur)

    actions.removeLocalBlur()
    #expect(host.writes == 2)
    #expect(host.document.feature.localBlur == nil)

    actions.resetAdjustments()
    #expect(host.writes == 3)
    #expect(host.document.feature == Self.plain)

    // Nothing left to remove or reset writes nothing.
    actions.removeFilter()
    actions.removeLocalBlur()
    actions.resetAdjustments()
    #expect(host.writes == 3)

    model.commit(.slider(.contrast, 30), to: host.binding)
    actions.revertToOriginal()
    #expect(host.writes == 5)
    #expect(host.document.feature == Self.plain)

    // A slider's live value is written as its own step first, as it is
    // before the toolbar's Revert.
    model.preview(.slider(.exposure, 40), in: host.binding)
    actions.revertToOriginal()
    #expect(host.writes == 7)
    #expect(host.document.feature == Self.plain)
    var undone = host.document
    undone.undo()
    #expect(undone.feature.effects.exposure != nil)
  }

  @Test func `The actions write through the binding of the editor's latest update`() throws {
    let (host, _, actions) = try makeEditor(Self.edited)
    // The host binds the editor to another document of the same image, and
    // the editor's next update hands the actions that binding.
    let other = ImageEditorModelTests.Host(host.document)
    actions.document = other.binding

    actions.removeFilter()
    #expect(host.writes == 0)
    #expect(other.writes == 1)
    #expect(other.document.feature.effects.preset == nil)
  }

  // MARK: - In a window

  /// Reads the scene's focused editor, as `ImageEditorCommands` does, and
  /// counts its own updates.
  struct FocusedEditorReader: View {

    @MainActor
    final class Box {
      private(set) var editor: Editor?
      private(set) var updates = 0

      func read(_ editor: Editor?) {
        self.editor = editor
        updates += 1
      }
    }

    @FocusedValue(\.imageEditor) private var editor
    let box: Box

    var body: some View {
      let _ = box.read(editor)

      Color.clear
    }
  }

  /// What the host shows: the editor as its navigation stack's root, a view
  /// pushed over it, or nothing once it closes the editor.
  @MainActor
  @Observable
  final class Navigation {
    var path: [Int] = []
    var showsEditor = true
  }

  /// The editor as a navigation stack's root, with the reader beside it in
  /// the same scene.
  struct CommandsHost: View {
    let host: ImageEditorWindowTests.Host
    let loader: PreviewSourceLoader
    let model: ImageEditorModel
    @Bindable var navigation: Navigation
    let reader: FocusedEditorReader.Box

    var body: some View {
      NavigationStack(path: $navigation.path) {
        Group {
          if navigation.showsEditor {
            ImageEditorContent(
              document: host.binding,
              previewSourceLoader: loader,
              options: ImageEditorCommandsTests.options,
              localizedStrings: .init(),
              onDone: {},
              onCancel: nil,
              model: model
            )
          }
        }
        .navigationDestination(for: Int.self) { _ in
          Text("Pushed")
        }
      }
      .background {
        FocusedEditorReader(box: reader)
      }
    }
  }

  /// The editor and the reader hosted in a 1200 × 800 window.
  @MainActor
  final class Mounted: WindowFixture {

    let host: ImageEditorWindowTests.Host
    let loader: PreviewSourceLoader
    let model: ImageEditorModel
    let navigation = Navigation()
    let reader = FocusedEditorReader.Box()
    let window: NSWindow
    let hostingView: NSView

    /// With `receivesClicks`, the window is ordered in far off every screen,
    /// so SwiftUI handles clicks in it.
    init(_ document: ImageEditorDocument, loader: PreviewSourceLoader, receivesClicks: Bool = false) {
      host = ImageEditorWindowTests.Host(document)
      self.loader = loader
      model = ImageEditorModel(documentAtStart: document, historyStep: .operation, analyze: { _ in nil })
      let hostingView = NSHostingView(
        rootView: CommandsHost(
          host: host,
          loader: loader,
          model: model,
          navigation: navigation,
          reader: reader
        )
      )
      hostingView.sceneBridgingOptions = [.title, .toolbars]
      self.hostingView = hostingView
      window = Self.makeWindow(
        showing: hostingView,
        size: CGSize(width: 1200, height: 800),
        receivesClicks: receivesClicks
      )
    }

    /// The editor as the reader last read it.
    var editor: Editor? {
      reader.editor
    }
  }

  private static func document() throws -> ImageEditorDocument {
    ImageEditorDocument(
      source: SourceImage(cgImage: try Fixtures.makeCGImage(width: 400, height: 200))
    )
  }

  /// The editor over a document whose image has already loaded.
  private static func mountLoaded(receivesClicks: Bool = false) async throws -> Mounted {
    let document = try document()
    let loader = PreviewSourceLoader(source: document.source)
    await loader.load()
    try #require(loader.previewSource != nil, "The image did not load")
    return Mounted(document, loader: loader, receivesClicks: receivesClicks)
  }

  @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
  func `The scene's focused values hold the editor, and its actions drive the editor`() async throws {
    let mounted = try await Self.mountLoaded()
    defer { mounted.close() }
    let canvas = try await mounted.drawnCanvas()

    // Nothing in the window has focus, so the value is the scene's rather
    // than a focused view's.
    try await mounted.wait(
      until: { mounted.editor?.canZoomIn == true },
      "The reader did not find the editor once the canvas reported its zoom"
    )
    let editor = try #require(mounted.editor)
    #expect(editor.actions.model === mounted.model)
    #expect(editor.canZoomOut == false)
    #expect(editor.canShowOriginal)
    #expect(editor.canRevert == false)
    #expect(editor.isHistogramVisible)
    #expect(editor.isFilterStripVisible)

    editor.actions.zoomIn()
    try await mounted.settleMotion(of: canvas)
    #expect(abs(canvas.navigation.position.scale - canvas.navigation.fitScale * 2) < 1e-6)
    try await mounted.wait(
      until: { mounted.editor?.canZoomOut == true },
      "Zoom Out and Zoom to Fit did not follow the zoom"
    )

    try #require(mounted.editor).actions.zoomToFit()
    try await mounted.settleMotion(of: canvas)
    #expect(canvas.navigation.isFitted)
    try await mounted.wait(
      until: { mounted.editor?.canZoomOut == false },
      "Zoom Out and Zoom to Fit did not follow the fit"
    )

    try #require(mounted.editor).actions.setHistogramVisible(false)
    #expect(mounted.model.isHistogramVisible == false)
    try await mounted.wait(
      until: { mounted.editor?.isHistogramVisible == false },
      "Show Histogram did not follow the histogram"
    )

    // The host's own change, as an undo would make it.
    mounted.host.document.feature.effects.exposure = ExposureFeature(ev: 0.5)
    try await mounted.wait(
      until: { mounted.editor?.canRevert == true },
      "Revert to Original did not follow the host's change"
    )
    try #require(mounted.editor).actions.revertToOriginal()
    #expect(mounted.host.writes == 1)
    #expect(mounted.host.document.feature.effects.exposure == nil)
    try await mounted.wait(
      until: { mounted.editor?.canRevert == false },
      "Revert to Original did not follow the revert"
    )
  }

  @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
  func `The editor stays in the scene's focused values while the filter strip has focus`() async throws {
    let mounted = try await Self.mountLoaded(receivesClicks: true)
    defer { mounted.close() }
    _ = try await mounted.drawnCanvas()
    try await mounted.wait(
      until: { mounted.filterStrip != nil },
      "The filter strip did not appear"
    )
    let strip = try #require(mounted.filterStrip)

    // A click on the preset's tile, after the Original tile at the strip's
    // leading edge, selects it and gives the strip the keyboard.
    let frame = strip.convert(strip.bounds, to: nil)
    try mounted.click(at: CGPoint(x: frame.minX + 100, y: frame.midY))
    try await mounted.wait(
      until: { mounted.host.writes == 1 },
      "The click did not select the preset"
    )
    try await mounted.wait(
      until: { mounted.editor?.canRemoveFilter == true },
      "Remove Filter did not follow the preset"
    )

    try #require(mounted.editor).actions.removeFilter()
    #expect(mounted.host.writes == 2)
    #expect(mounted.host.document.feature.effects.preset == nil)
    try await mounted.wait(
      until: { mounted.editor?.canRemoveFilter == false },
      "Remove Filter did not follow the removal"
    )

    // The strip kept the keyboard: the arrow selects the preset again.
    try mounted.press(.rightArrow)
    try await mounted.wait(
      until: { mounted.host.writes == 3 },
      "The arrow did not select the preset"
    )
    try await mounted.wait(
      until: { mounted.editor?.canRemoveFilter == true },
      "Remove Filter did not follow the arrow's preset"
    )
  }

  @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
  func `The editor stays in the scene's focused values while a slider in the inspector has focus`() async throws {
    let mounted = try await Self.mountLoaded()
    defer { mounted.close() }
    _ = try await mounted.drawnCanvas()
    let exposure = try await mounted.slider("image-editor.adjust.exposure")
    try #require(mounted.window.makeFirstResponder(exposure))
    try await mounted.wait(
      until: { mounted.editor != nil },
      "The reader did not find the editor while the slider had focus"
    )

    // An edit while the slider has focus: Reset Adjustments follows it and
    // acts, and the slider keeps the keyboard.
    mounted.model.commit(.slider(.exposure, 40), to: mounted.host.binding)
    try await mounted.wait(
      until: { mounted.editor?.canResetAdjustments == true },
      "Reset Adjustments did not follow the edit"
    )
    try #require(mounted.editor).actions.resetAdjustments()
    #expect(mounted.host.writes == 2)
    #expect(mounted.host.document.feature.effects.exposure == nil)
    try await mounted.wait(
      until: { mounted.editor?.canResetAdjustments == false },
      "Reset Adjustments did not follow the reset"
    )
    #expect(mounted.window.firstResponder === exposure)
  }

  @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
  func `The editor stays in the scene's focused values while the photo has the keyboard`() async throws {
    let mounted = try await Self.mountLoaded(receivesClicks: true)
    defer { mounted.close() }
    let canvas = try await mounted.drawnCanvas()
    try await mounted.wait(
      until: { mounted.editor?.canZoomIn == true },
      "The reader did not find the editor"
    )

    // Zoomed in, a click on the photo gives it the keyboard.
    try #require(mounted.editor).actions.zoomIn()
    try await mounted.settleMotion(of: canvas)
    try mounted.click(at: canvas.convert(CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY), to: nil))
    try await mounted.wait(
      until: { mounted.window.firstResponder === canvas },
      "A click on the zoomed photo did not give it the keyboard"
    )

    // An edit while the photo has the keyboard: Reset Adjustments follows it.
    mounted.model.commit(.slider(.exposure, 40), to: mounted.host.binding)
    try await mounted.wait(
      until: { mounted.editor?.canResetAdjustments == true },
      "Reset Adjustments did not follow the edit while the photo had the keyboard"
    )

    // Zoom to Fit acts on the photo, the zoom items follow the fit, and the
    // photo keeps the keyboard.
    try #require(mounted.editor).actions.zoomToFit()
    try await mounted.settleMotion(of: canvas)
    #expect(canvas.navigation.isFitted)
    try await mounted.wait(
      until: { mounted.editor?.canZoomOut == false },
      "Zoom Out and Zoom to Fit did not follow the fit while the photo had the keyboard"
    )
    #expect(mounted.window.firstResponder === canvas)
    #expect(mounted.host.writes == 1)
  }

  @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
  func `Reset Adjustments is enabled exactly when the inspector's footer menu is`() async throws {
    let mounted = try await Self.mountLoaded()
    defer { mounted.close() }
    _ = try await mounted.drawnCanvas()
    _ = try await mounted.slider("image-editor.adjust.exposure")
    // SwiftUI backs the footer's menu with the inspector's only
    // `NSPopUpButton`.
    let footerMenu = try #require(Mounted.all(NSPopUpButton.self, in: mounted.hostingView).first)
    func agree(_ isEnabled: Bool) -> Bool {
      footerMenu.isEnabled == isEnabled && mounted.editor?.canResetAdjustments == isEnabled
    }
    try await mounted.wait(until: { agree(false) }, "Something is enabled with nothing to reset")

    // A value still being dragged.
    mounted.model.preview(.slider(.exposure, 40), in: mounted.host.binding)
    try await mounted.wait(until: { agree(true) }, "The two disagree during a drag")

    // Only kept values, in a section switched off.
    mounted.model.commit(.slider(.exposure, 40), to: mounted.host.binding)
    mounted.model.setSection(.basic, isOn: false, in: mounted.host.binding)
    try await mounted.wait(
      until: { mounted.model.switchState(of: .basic, in: mounted.host.document) == .off },
      "Basic is not switched off"
    )
    try await mounted.wait(until: { agree(true) }, "The two disagree over kept values")

    try #require(mounted.editor).actions.resetAdjustments()
    try await mounted.wait(until: { agree(false) }, "The two disagree after the reset")
  }

  @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
  func `The editor leaves the scene's focused values under a pushed view and once it closes`() async throws {
    let mounted = try await Self.mountLoaded()
    defer { mounted.close() }
    _ = try await mounted.drawnCanvas()
    try await mounted.wait(
      until: { mounted.editor != nil },
      "The reader did not find the editor"
    )

    mounted.navigation.path = [1]
    try await mounted.wait(
      until: { mounted.editor == nil },
      "The editor stayed in the focused values under the pushed view"
    )
    mounted.navigation.path = []
    try await mounted.wait(
      until: { mounted.editor != nil },
      "The editor did not come back when the pushed view went"
    )

    mounted.navigation.showsEditor = false
    try await mounted.wait(
      until: { mounted.editor == nil },
      "The editor stayed in the focused values after the host closed it"
    )
    #expect(mounted.host.writes == 0)
  }

  /// `NSSplitViewController.toggleInspector(_:)` is AppKit's action for a
  /// split view's inspector; it reaches the inspector from a view inside
  /// the editor through the responder chain.
  @Test(
    .enabled(if: MTLCreateSystemDefaultDevice() != nil),
    .enabled(if: hasActiveDisplay(), "The inspector's animation needs a display that can draw")
  )
  func `AppKit's inspector toggle hides and shows the adjustments and writes nothing`() async throws {
    let mounted = try await Self.mountLoaded()
    defer { mounted.close() }
    _ = try await mounted.drawnCanvas()
    let exposure = try await mounted.slider("image-editor.adjust.exposure")
    let toggleInspector = #selector(NSSplitViewController.toggleInspector(_:))
    let splitViewController = try #require(
      sequence(first: exposure as NSResponder, next: \.nextResponder)
        .first { $0.responds(to: toggleInspector) } as? NSSplitViewController,
      "No split view controller above the inspector takes the toggle"
    )
    // The inspector animates in as the editor opens; a toggle during that
    // animation is undone by it.
    try await mounted.settleInspector()
    #expect(mounted.model.selectedTool == .adjust)

    splitViewController.toggleInspector(nil)
    try await mounted.wait(
      until: { mounted.model.selectedTool == nil },
      "The toggle did not hide the adjustments"
    )
    try await mounted.settleInspector()
    #expect(mounted.model.selectedTool == nil)

    splitViewController.toggleInspector(nil)
    try await mounted.wait(
      until: { mounted.model.selectedTool == .adjust },
      "The toggle did not show the adjustments"
    )
    try await mounted.settleInspector()
    #expect(mounted.model.selectedTool == .adjust)
    #expect(mounted.host.writes == 0)
  }

  @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
  func `Until the image loads the zoom items are off, and the window leaves the zoom keys to them`() async throws {
    let document = try Self.document()
    let (opening, gate) = AsyncStream<Void>.makeStream()
    defer { gate.finish() }
    // The preparation waits until the test finishes the gate.
    let loader = PreviewSourceLoader(source: document.source) { source in
      for await _ in opening {}
      return await PreviewSource.make(from: source)
    }
    let mounted = Mounted(document, loader: loader)
    defer { mounted.close() }

    try await mounted.wait(
      until: { loader.phase == .loading && mounted.editor != nil },
      "The reader did not find the loading editor"
    )
    let loading = try #require(mounted.editor)
    #expect(loading.canZoomIn == false)
    #expect(loading.canZoomOut == false)
    #expect(loading.canShowOriginal == false)
    #expect(loading.isHistogramVisible)
    #expect(try mounted.pressKeyEquivalent("=", modifiers: .command, keyCode: 24) == false)
    #expect(try mounted.pressKeyEquivalent("0", modifiers: .command, keyCode: 29) == false)

    // Once the item is on, the window takes its key, so the menu bar never
    // runs it a second time.
    gate.finish()
    let canvas = try await mounted.drawnCanvas()
    try await mounted.wait(
      until: { mounted.editor?.canZoomIn == true },
      "Zoom In did not follow the load"
    )
    #expect(try mounted.pressKeyEquivalent("+", modifiers: [.command, .shift], keyCode: 24))
    try await mounted.settleMotion(of: canvas)
    #expect(abs(canvas.navigation.position.scale - canvas.navigation.fitScale * 2) < 1e-6)
    #expect(mounted.host.writes == 0)
  }

  @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
  func `A slider drag updates the scene's focused editor only when an item changes`() async throws {
    let mounted = try await Self.mountLoaded()
    defer { mounted.close() }
    _ = try await mounted.drawnCanvas()
    try await mounted.wait(
      until: { mounted.editor?.canZoomIn == true },
      "The reader did not find the editor"
    )
    try await mounted.settle()

    // The first step enables Revert to Original and Reset Adjustments.
    mounted.model.preview(.slider(.exposure, 10), in: mounted.host.binding)
    try await mounted.wait(
      until: { mounted.editor?.canRevert == true && mounted.editor?.canResetAdjustments == true },
      "Revert and Reset did not follow the drag"
    )
    try await mounted.settle()
    let updates = mounted.reader.updates

    for value in stride(from: 20.0, through: 60, by: 10) {
      mounted.model.preview(.slider(.exposure, value), in: mounted.host.binding)
      try await mounted.settle()
    }
    #expect(mounted.reader.updates == updates, "Steps that changed no item updated the reader.")
    #expect(mounted.host.writes == 0)
  }
}

#endif
