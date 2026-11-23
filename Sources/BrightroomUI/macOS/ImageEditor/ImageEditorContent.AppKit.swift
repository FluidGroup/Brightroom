// The macOS counterpart of iOS/ImageEditor/ImageEditorContent.swift. It has
// the same type name, because `ImageEditor` shows the platform's editor, and
// a `.AppKit` file name suffix because one module cannot contain two files
// with the same name.

#if os(macOS)
import BrightroomEngine
import BrightroomParametric
import SwiftUI

/// The macOS editor `ImageEditor` shows: the image on a dark column, with a
/// histogram and a status badge over it and the filter strip under it; the
/// editor's items in the window's toolbar; and the adjustments in an
/// inspector beside the image.
///
/// The model holds the editor's state and makes every write. The editor
/// reports the binding's changes to it, so an outside change, such as the
/// host's undo, drops a value in progress, as leaving the screen does.
struct ImageEditorContent: View {

  @Binding private var document: ImageEditorDocument
  private let previewSourceLoader: PreviewSourceLoader
  private let options: ImageEditor.Options
  private let localizedStrings: ImageEditor.LocalizedStrings
  private let onDone: @MainActor () -> Void
  private let onCancel: (@MainActor () -> Void)?

  /// The first model of the editor's identity (one per image) stays, so it
  /// holds the document the editor opened with.
  @State private var model: ImageEditorModel

  /// What the menu bar's `ImageEditorCommands` act through, made with the
  /// first model.
  @State private var commandActions: ImageEditorCommands.Editor.Actions

  init(
    document: Binding<ImageEditorDocument>,
    previewSourceLoader: PreviewSourceLoader,
    options: ImageEditor.Options,
    localizedStrings: ImageEditor.LocalizedStrings,
    onDone: @escaping @MainActor () -> Void,
    onCancel: (@MainActor () -> Void)?
  ) {
    self.init(
      document: document,
      previewSourceLoader: previewSourceLoader,
      options: options,
      localizedStrings: localizedStrings,
      onDone: onDone,
      onCancel: onCancel,
      model: ImageEditorModel(documentAtStart: document.wrappedValue, historyStep: .operation)
    )
  }

  /// Mounts the editor with `model`, so tests can drive it.
  init(
    document: Binding<ImageEditorDocument>,
    previewSourceLoader: PreviewSourceLoader,
    options: ImageEditor.Options,
    localizedStrings: ImageEditor.LocalizedStrings,
    onDone: @escaping @MainActor () -> Void,
    onCancel: (@MainActor () -> Void)?,
    model: ImageEditorModel
  ) {
    self._document = document
    self.previewSourceLoader = previewSourceLoader
    self.options = options
    self.localizedStrings = localizedStrings
    self.onDone = onDone
    self.onCancel = onCancel
    self._model = State(initialValue: model)
    self._commandActions = State(initialValue: .init(model: model, document: document, options: options))
  }

  var body: some View {
    let isLoaded = previewSourceLoader.previewSource != nil
    let isInspectorPresented = model.selectedTool != nil

    VStack(spacing: 0) {
      // First, so the canvas keeps its place, and with it its zoom and its
      // caches, while the strip, the histogram and the inspector come and go.
      CanvasArea(
        model: model,
        document: $document,
        previewSourceLoader: previewSourceLoader,
        localizedStrings: localizedStrings
      )

      if model.isFilterStripVisible, options.hasFilters, let previewSource = previewSourceLoader.previewSource {
        FilterStrip(
          model: model,
          document: $document,
          groups: options.stripGroups,
          previewSource: previewSource,
          localizedStrings: localizedStrings
        )
      }
    }
    // The dark surround reaches under the toolbar but not under the
    // inspector's glass, which shows what lies behind it.
    .background(.background, ignoresSafeAreaEdges: .vertical)
    // The image column only: the toolbar and the inspector follow the
    // window's appearance.
    .environment(\.colorScheme, .dark)
    .frame(minWidth: 480, minHeight: 360)
    // In a navigation stack, Cancel is the only back chevron.
    .navigationBarBackButtonHidden(onCancel != nil)
    .toolbar {
      ImageEditorToolbar(
        model: model,
        document: $document,
        previewSourceLoader: previewSourceLoader,
        options: options,
        localizedStrings: localizedStrings,
        onDone: onDone,
        onCancel: onCancel
      )
    }
    .background {
      ImageEditorKeyCommands(model: model, localizedStrings: localizedStrings, isLoaded: isLoaded)

      HoldKeyMonitor(key: "m", isEnabled: isLoaded) { model.setHoldingOriginal($0) }

      focusedEditor
    }
    .inspector(isPresented: Binding { isInspectorPresented } set: { model.setInspectorPresented($0) }) {
      AdjustmentInspector(
        model: model,
        document: $document,
        isLoaded: isLoaded,
        localizedStrings: localizedStrings
      )
      // The inspector's views are hosted apart from the column's, and the
      // column's focused values do not reach them, so the inspector
      // publishes the editor too.
      .background {
        focusedEditor
      }
      .inspectorColumnWidth(min: 280, ideal: 330, max: 420)
    }
    .onChange(of: document) { old, new in
      model.documentDidChange(from: old, to: new)
    }
    .onDisappear {
      model.editorDidDisappear()
    }
    .task {
      await previewSourceLoader.load()
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("image-editor")
  }

  /// Publishes the editor for its scene; the menu bar's
  /// `ImageEditorCommands` find it through this.
  private var focusedEditor: some View {
    ImageEditorCommands.FocusedEditor(
      actions: commandActions,
      document: $document,
      previewSourceLoader: previewSourceLoader,
      options: options
    )
  }
}

extension ImageEditorContent {

  /// The canvas, with the histogram over its top leading corner once the
  /// image has loaded and the status badge at its top centre. While the gray
  /// point is on, a click on the image samples it.
  ///
  /// A view of its own, so a drag re-evaluates it and not the editor around
  /// it. It asks for an analysis of what the canvas shows whenever that
  /// changes, and again when it appears, because leaving the screen stops
  /// the analysis.
  private struct CanvasArea: View {

    let model: ImageEditorModel
    @Binding var document: ImageEditorDocument
    let previewSourceLoader: PreviewSourceLoader
    let localizedStrings: ImageEditor.LocalizedStrings

    @Environment(\.adjustmentRendering) private var adjustmentRendering

    var body: some View {
      let feature = model.canvasFeature(of: document)
      // Nothing to analyse while the histogram is hidden or the image has
      // not loaded.
      let request: OutputAnalysis.Request? = if model.isHistogramVisible, let previewSource = previewSourceLoader.previewSource {
        OutputAnalysis.Request(
          previewSource: previewSource,
          feature: feature,
          adjustmentRendering: adjustmentRendering
        )
      } else {
        nil
      }

      ZStack(alignment: .topLeading) {
        ImageEditorCanvas(
          document: model.canvasBinding(for: $document),
          displayedFeature: feature,
          previewSourceLoader: previewSourceLoader,
          failureMessage: localizedStrings.imageLoadFailed
        )
        .editingTarget(nil)
        // The photo keeps the column's margin at the fit.
        .fitMargin(12)
        .canvasAccessibilityLabel(localizedStrings.photo)
        .onZoomChange { model.canvasDidReportZoom($0) }
        .onPointerChange { model.canvasDidReportPointer($0) }
        .pointSampling(grayPointSampling)

        if model.isHistogramVisible, previewSourceLoader.previewSource != nil {
          HistogramPanel(model: model, localizedStrings: localizedStrings)
            .padding(12)
            .allowsHitTesting(false)
        }
      }
      .overlay(alignment: .top) {
        StatusBadge(model: model, localizedStrings: localizedStrings)
      }
      // The zoom commands reach the canvas through the model's registry.
      .environment(\.imageEditorCanvasRegistry, model.canvasRegistry)
      .onAppear {
        model.requestAnalysis(request)
      }
      .onChange(of: request) { _, request in
        model.requestAnalysis(request)
      }
    }

    /// Samples the gray point at a clicked point while it is on and the image
    /// has loaded; nil otherwise, so a click pans.
    private var grayPointSampling: (@MainActor (CGPoint) -> Void)? {
      guard
        model.grayPointSampling != .off,
        let previewSource = previewSourceLoader.previewSource
      else {
        return nil
      }
      let model = model
      let document = $document
      let rendering = adjustmentRendering
      return { point in
        model.sampleGrayPoint(
          atOutputPoint: point,
          previewSource: previewSource,
          rendering: rendering,
          in: document
        )
      }
    }
  }
}
#endif
