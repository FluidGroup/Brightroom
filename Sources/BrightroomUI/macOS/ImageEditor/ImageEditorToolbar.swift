#if os(macOS)
import BrightroomEngine
import SwiftUI

/// The macOS editor's items in the window's toolbar, around the host's title
/// and subtitle. Leading: Cancel (only with `onCancel`), Show Original, Revert
/// to Original and zoom. Trailing: the tools, which show the inspector, More,
/// and Done.
///
/// The content reads nothing itself: each item that reads the model, the
/// document or the loader is a view of its own, so a drag re-evaluates only
/// the items that show the value in progress.
struct ImageEditorToolbar: ToolbarContent {

  private let model: ImageEditorModel
  @Binding private var document: ImageEditorDocument
  private let previewSourceLoader: PreviewSourceLoader
  private let options: ImageEditor.Options
  private let localizedStrings: ImageEditor.LocalizedStrings
  private let onDone: @MainActor () -> Void
  private let onCancel: (@MainActor () -> Void)?

  /// `onDone` runs once a value in progress has been written to the binding,
  /// and `onCancel` once the binding holds the document the editor opened
  /// with; nil hides Cancel.
  init(
    model: ImageEditorModel,
    document: Binding<ImageEditorDocument>,
    previewSourceLoader: PreviewSourceLoader,
    options: ImageEditor.Options,
    localizedStrings: ImageEditor.LocalizedStrings,
    onDone: @escaping @MainActor () -> Void,
    onCancel: (@MainActor () -> Void)?
  ) {
    self.model = model
    self._document = document
    self.previewSourceLoader = previewSourceLoader
    self.options = options
    self.localizedStrings = localizedStrings
    self.onDone = onDone
    self.onCancel = onCancel
  }

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .navigation) {
      // A back chevron with no key: it discards everything written since
      // the editor opened.
      if let onCancel {
        Button {
          model.cancel($document)
          onCancel()
        } label: {
          Label(localizedStrings.cancel, systemImage: "chevron.backward")
        }
        .help(localizedStrings.cancel)
        .accessibilityIdentifier("image-editor.cancel")
      }

      CompareToggle(
        model: model,
        previewSourceLoader: previewSourceLoader,
        localizedStrings: localizedStrings
      )

      RevertButton(
        model: model,
        document: $document,
        previewSourceLoader: previewSourceLoader,
        options: options,
        localizedStrings: localizedStrings
      )

      ZoomControl(model: model, localizedStrings: localizedStrings)
    }

    ToolbarItemGroup(placement: .primaryAction) {
      ToolToggles(model: model, localizedStrings: localizedStrings)

      MoreMenu(
        model: model,
        document: $document,
        previewSourceLoader: previewSourceLoader,
        options: options,
        localizedStrings: localizedStrings
      )
    }

    ToolbarItem(placement: .confirmationAction) {
      DoneButton(
        model: model,
        document: $document,
        previewSourceLoader: previewSourceLoader,
        localizedStrings: localizedStrings,
        onDone: onDone
      )
    }
  }
}

extension ImageEditorToolbar {

  /// Show Original: the canvas shows what Revert to Original restores, until
  /// the toggle or an edit ends it. Holding M does the same while it is held.
  /// The toggle shows on whenever the canvas shows the original, a held M
  /// included; a click sets the toggle's own state.
  private struct CompareToggle: View {

    let model: ImageEditorModel
    let previewSourceLoader: PreviewSourceLoader
    let localizedStrings: ImageEditor.LocalizedStrings

    var body: some View {
      let showsOriginal = model.showsOriginal

      Toggle(isOn: Binding { showsOriginal } set: { model.setComparing($0) }) {
        Label(
          localizedStrings.showOriginal,
          systemImage: "square.filled.and.line.vertical.and.square"
        )
      }
      .toggleStyle(.button)
      .help("\(localizedStrings.showOriginal) (hold M)")
      .disabled(previewSourceLoader.previewSource == nil)
      .accessibilityIdentifier("image-editor.compare")
    }
  }

  /// Revert to Original, enabled once the image has loaded while an effect
  /// shows or the crop has changed.
  private struct RevertButton: View {

    let model: ImageEditorModel
    @Binding var document: ImageEditorDocument
    let previewSourceLoader: PreviewSourceLoader
    let options: ImageEditor.Options
    let localizedStrings: ImageEditor.LocalizedStrings

    var body: some View {
      let isLoaded = previewSourceLoader.previewSource != nil

      Button(localizedStrings.revertToOriginal) {
        model.revertToOriginal(in: $document, options: options)
      }
      .disabled(model.canRevert(document, options: options, isLoaded: isLoaded) == false)
      .accessibilityIdentifier("image-editor.revert")
    }
  }

  /// Zoom out, a slider from the fit to the largest zoom, and zoom in. The
  /// buttons zoom by a factor of two, as Command-minus and Command-plus do,
  /// and the slider zooms at once. All three wait for the canvas's first
  /// zoom report.
  private struct ZoomControl: View {

    let model: ImageEditorModel
    let localizedStrings: ImageEditor.LocalizedStrings

    var body: some View {
      let zoom = model.zoom

      // A borderless button is otherwise only as large as its glyph, so
      // each takes a 24 × 24 target.
      HStack(spacing: 4) {
        Button {
          model.zoomOut()
        } label: {
          Label(localizedStrings.zoomOut, systemImage: "minus")
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .help("\(localizedStrings.zoomOut) (⌘−)")
        .disabled(zoom?.isFitted ?? true)

        Slider(
          value: Binding { zoom?.fraction ?? 0 } set: { model.setZoomFraction($0) },
          in: 0...1
        )
        .controlSize(.mini)
        .frame(width: 90)
        .disabled(zoom == nil)
        .accessibilityLabel(localizedStrings.zoom)
        // Device pixels per pixel of the output, such as "36%".
        .accessibilityValue(zoom?.percent.formatted(.percent) ?? "")
        .accessibilityIdentifier("image-editor.zoom")

        Button {
          model.zoomIn()
        } label: {
          Label(localizedStrings.zoomIn, systemImage: "plus")
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .help("\(localizedStrings.zoomIn) (⌘+)")
        .disabled(zoom?.isAtMaximum ?? true)
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
    }
  }

  /// A toggle for each tool: selecting one shows the inspector with its
  /// controls, and deselecting it hides the inspector.
  private struct ToolToggles: View {

    let model: ImageEditorModel
    let localizedStrings: ImageEditor.LocalizedStrings

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
      let selectedTool = model.selectedTool

      ForEach(ImageEditorModel.Tool.allCases) { tool in
        let isSelected = Binding {
          selectedTool == tool
        } set: { isOn in
          withAnimation(reduceMotion ? nil : .default) {
            if isOn {
              model.select(tool)
            } else {
              model.select(nil)
            }
          }
        }

        switch tool {
        case .adjust:
          Toggle(isOn: isSelected) {
            Label(localizedStrings.adjust, systemImage: "slider.horizontal.3")
          }
          .toggleStyle(.button)
          .help("\(localizedStrings.adjust) (⌃⌘I)")
          .accessibilityIdentifier("image-editor.tool.adjust")
        }
      }
    }
  }

  /// More: Show Histogram, and Show Filters when the host gives presets;
  /// then Remove Filter while a preset is applied and Remove Painted Blur
  /// while the document has a painted blur, each one write, enabled once the
  /// image has loaded.
  private struct MoreMenu: View {

    let model: ImageEditorModel
    @Binding var document: ImageEditorDocument
    let previewSourceLoader: PreviewSourceLoader
    let options: ImageEditor.Options
    let localizedStrings: ImageEditor.LocalizedStrings

    var body: some View {
      // The document's feature, not the value in progress: a drag changes
      // neither the preset nor the painted blur.
      let feature = document.feature
      let hasPreset = feature.effects.preset != nil
      let hasLocalBlur = feature.localBlur != nil
      let isLoaded = previewSourceLoader.previewSource != nil
      let isHistogramVisible = model.isHistogramVisible
      let isFilterStripVisible = model.isFilterStripVisible

      Menu {
        Toggle(
          localizedStrings.showHistogram,
          isOn: Binding { isHistogramVisible } set: { model.setHistogramVisible($0) }
        )

        if options.hasFilters {
          Toggle(
            localizedStrings.showFilters,
            isOn: Binding { isFilterStripVisible } set: { model.setFilterStripVisible($0) }
          )
        }

        if hasPreset || hasLocalBlur {
          Divider()
        }

        if hasPreset {
          Button(localizedStrings.removeFilter) {
            model.selectPreset(nil, in: $document)
          }
          .disabled(model.canRemoveFilter(document, isLoaded: isLoaded) == false)
        }

        if hasLocalBlur {
          Button(localizedStrings.removePaintedBlur) {
            model.removeLocalBlur(in: $document)
          }
          .disabled(model.canRemoveLocalBlur(document, isLoaded: isLoaded) == false)
        }
      } label: {
        Label(localizedStrings.more, systemImage: "ellipsis.circle")
      }
      .menuIndicator(.visible)
      .help(localizedStrings.more)
      .accessibilityIdentifier("image-editor.more")
    }
  }

  /// Done, the default button (Return): ends the gray point, so that no
  /// solve in progress is written after `onDone`, writes a value in
  /// progress, then calls `onDone`. It is enabled once the image has loaded,
  /// and after a failed load, which leaves it the way out.
  private struct DoneButton: View {

    let model: ImageEditorModel
    @Binding var document: ImageEditorDocument
    let previewSourceLoader: PreviewSourceLoader
    let localizedStrings: ImageEditor.LocalizedStrings
    let onDone: @MainActor () -> Void

    var body: some View {
      let isEnabled = previewSourceLoader.previewSource != nil
        || previewSourceLoader.phase == .failed

      Button(localizedStrings.done) {
        model.cancelGrayPointSampling()
        model.flush($document)
        onDone()
      }
      .buttonStyle(.borderedProminent)
      .keyboardShortcut(.defaultAction)
      .disabled(isEnabled == false)
      .accessibilityIdentifier("image-editor.done")
    }
  }
}
#endif
