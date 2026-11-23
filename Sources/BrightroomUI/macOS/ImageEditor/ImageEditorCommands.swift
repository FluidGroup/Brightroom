#if os(macOS)
import BrightroomEngine
import SwiftUI

/**
 The macOS editor's commands in the menu bar. Add them to the scene that
 shows `ImageEditor`, beside the system's `InspectorCommands`, and give them
 the strings you give the editor:

 ```swift
 WindowGroup {
   ContentView()
 }
 .commands {
   InspectorCommands()
   ImageEditorCommands()
 }
 ```

 - The View menu gets Zoom In (Command-plus; the editor's window also takes
   Command-equals), Zoom Out (Command-minus), Zoom to Fit (Command-0), and
   Show Original, Show Histogram and Show Filters, which show a checkmark
   while they are on. `InspectorCommands` adds Show Inspector
   (Control-Command-I), which shows and hides the editor's adjustments.
   These commands leave that item to it, because a scene that adds
   `InspectorCommands` twice shows the item twice.
 - A new Image menu gets Revert to Original, Reset Adjustments, Remove
   Filter and Remove Painted Blur.
 - The items act on the editor in the key window, wherever focus is in it,
   through the actions of the editor's own controls. Each is enabled when
   its control is, and Zoom to Fit when Zoom Out is. Without an editor in
   the key window, they are disabled.
 - The editor's keys work without these commands. With them, the editor's
   window takes each key before the menu bar does, so a key runs its
   command once.
 */
public struct ImageEditorCommands: Commands {

  private let localizedStrings: ImageEditor.LocalizedStrings

  @FocusedValue(\.imageEditor) private var editor

  /// `localizedStrings` titles the items and the Image menu.
  public init(localizedStrings: ImageEditor.LocalizedStrings = .init()) {
    self.localizedStrings = localizedStrings
  }

  public var body: some Commands {
    // After the toolbar's items and before the sidebar's, where
    // `InspectorCommands` puts Show Inspector.
    CommandGroup(after: .toolbar) {
      Button(localizedStrings.zoomIn) {
        editor?.actions.zoomIn()
      }
      .keyboardShortcut("+", modifiers: .command)
      .disabled(editor?.canZoomIn != true)

      Button(localizedStrings.zoomOut) {
        editor?.actions.zoomOut()
      }
      .keyboardShortcut("-", modifiers: .command)
      .disabled(editor?.canZoomOut != true)

      Button(localizedStrings.zoomToFit) {
        editor?.actions.zoomToFit()
      }
      .keyboardShortcut("0", modifiers: .command)
      .disabled(editor?.canZoomOut != true)

      Divider()

      Toggle(
        localizedStrings.showOriginal,
        isOn: Binding {
          editor?.showsOriginal ?? false
        } set: {
          editor?.actions.setComparing($0)
        }
      )
      .disabled(editor?.canShowOriginal != true)

      Toggle(
        localizedStrings.showHistogram,
        isOn: Binding {
          editor?.isHistogramVisible ?? false
        } set: {
          editor?.actions.setHistogramVisible($0)
        }
      )
      .disabled(editor == nil)

      Toggle(
        localizedStrings.showFilters,
        isOn: Binding {
          editor?.isFilterStripVisible ?? false
        } set: {
          editor?.actions.setFilterStripVisible($0)
        }
      )
      .disabled(editor?.hasFilters != true)
    }

    CommandMenu(localizedStrings.imageMenu) {
      Button(localizedStrings.revertToOriginal) {
        editor?.actions.revertToOriginal()
      }
      .disabled(editor?.canRevert != true)

      Button(localizedStrings.resetAdjustmentsMenuItem) {
        editor?.actions.resetAdjustments()
      }
      .disabled(editor?.canResetAdjustments != true)

      Divider()

      Button(localizedStrings.removeFilter) {
        editor?.actions.removeFilter()
      }
      .disabled(editor?.canRemoveFilter != true)

      Button(localizedStrings.removePaintedBlur) {
        editor?.actions.removeLocalBlur()
      }
      .disabled(editor?.canRemoveLocalBlur != true)
    }
  }
}

extension ImageEditorCommands {

  /// An editor as its commands see it: which items are enabled, which show
  /// a checkmark, and what they do. `FocusedEditor` publishes it for the
  /// editor's scene.
  ///
  /// Values with the same states and the same actions are equal, so an
  /// update that changes no item, such as a step of a slider drag, leaves
  /// the menu bar alone.
  struct Editor: Equatable {

    /// Acts on one editor as its controls do, through the binding and the
    /// options of the editor's latest update. Equal only to itself.
    @MainActor
    final class Actions: Equatable {

      let model: ImageEditorModel
      var document: Binding<ImageEditorDocument>
      var options: ImageEditor.Options

      init(
        model: ImageEditorModel,
        document: Binding<ImageEditorDocument>,
        options: ImageEditor.Options
      ) {
        self.model = model
        self.document = document
        self.options = options
      }

      nonisolated static func == (lhs: Actions, rhs: Actions) -> Bool {
        lhs === rhs
      }

      func zoomIn() {
        model.zoomIn()
      }

      func zoomOut() {
        model.zoomOut()
      }

      func zoomToFit() {
        model.zoomToFit()
      }

      /// Show Original, as the toolbar's toggle turns it on and off.
      func setComparing(_ comparing: Bool) {
        model.setComparing(comparing)
      }

      func setHistogramVisible(_ visible: Bool) {
        model.setHistogramVisible(visible)
      }

      func setFilterStripVisible(_ visible: Bool) {
        model.setFilterStripVisible(visible)
      }

      func revertToOriginal() {
        model.revertToOriginal(in: document, options: options)
      }

      func resetAdjustments() {
        model.resetAdjustments(in: document)
      }

      func removeFilter() {
        model.selectPreset(nil, in: document)
      }

      func removeLocalBlur() {
        model.removeLocalBlur(in: document)
      }
    }

    let canZoomIn: Bool
    /// Zoom Out, and Zoom to Fit: the canvas is zoomed in from the fit.
    let canZoomOut: Bool
    let canShowOriginal: Bool
    /// Whether the canvas shows the original, from the toggle or a held M.
    let showsOriginal: Bool
    let isHistogramVisible: Bool
    /// Show Filters is enabled: the host gives presets.
    let hasFilters: Bool
    /// Whether the filter strip shows.
    let isFilterStripVisible: Bool
    let canRevert: Bool
    let canResetAdjustments: Bool
    let canRemoveFilter: Bool
    let canRemoveLocalBlur: Bool
    let actions: Actions

    /// The states of the editor of `actions` over `document`, read as the
    /// editor's controls read them.
    @MainActor
    init(actions: Actions, document: ImageEditorDocument, isLoaded: Bool) {
      let model = actions.model
      let options = actions.options
      let zoom = model.zoom

      self.canZoomIn = zoom.map { $0.isAtMaximum == false } ?? false
      self.canZoomOut = zoom.map { $0.isFitted == false } ?? false
      self.canShowOriginal = isLoaded
      self.showsOriginal = model.showsOriginal
      self.isHistogramVisible = model.isHistogramVisible
      self.hasFilters = options.hasFilters
      self.isFilterStripVisible = options.hasFilters && model.isFilterStripVisible
      self.canRevert = model.canRevert(document, options: options, isLoaded: isLoaded)
      self.canResetAdjustments = isLoaded && model.canResetAdjustments(in: document)
      self.canRemoveFilter = model.canRemoveFilter(document, isLoaded: isLoaded)
      self.canRemoveLocalBlur = model.canRemoveLocalBlur(document, isLoaded: isLoaded)
      self.actions = actions
    }
  }

  /// Publishes the editor for its scene, so the commands follow it and act
  /// on it whichever view of the window has focus.
  ///
  /// A view of its own: what changes during a drag re-evaluates it alone,
  /// and the value it publishes changes only when an item's state does.
  struct FocusedEditor: View {

    private let actions: Editor.Actions
    @Binding private var document: ImageEditorDocument
    private let previewSourceLoader: PreviewSourceLoader
    private let options: ImageEditor.Options

    /// `actions` is the editor's one instance, so every view that publishes
    /// the editor publishes equal values; each update hands it the current
    /// binding and options.
    init(
      actions: Editor.Actions,
      document: Binding<ImageEditorDocument>,
      previewSourceLoader: PreviewSourceLoader,
      options: ImageEditor.Options
    ) {
      self.actions = actions
      self._document = document
      self.previewSourceLoader = previewSourceLoader
      self.options = options
    }

    var body: some View {
      let _ = actions.document = $document
      let _ = actions.options = options

      Color.clear
        .frame(width: 0, height: 0)
        .focusedSceneValue(
          \.imageEditor,
          Editor(
            actions: actions,
            document: document,
            isLoaded: previewSourceLoader.previewSource != nil
          )
        )
    }
  }
}

extension FocusedValues {

  /// The editor in the focused scene, which `ImageEditorCommands` acts on.
  @Entry var imageEditor: ImageEditorCommands.Editor?
}
#endif
