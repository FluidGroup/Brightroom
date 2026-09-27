//
// Copyright (c) 2026 Muukii <muukii.app@gmail.com>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import BrightroomEngine
import BrightroomParametric
import CoreImage
import SwiftUI
import UIKit

struct ImageEditorContent: View {

  @Binding var document: ImageEditorDocument
  let editingStack: EditingStack
  let options: ImageEditor.Options
  let localizedStrings: ImageEditor.LocalizedStrings
  let onDone: @MainActor () -> Void
  let onCancel: (@MainActor () -> Void)?

  /// Created once per editor identity (one per image), so it keeps the
  /// document as it was when the editor opened. It restarts itself when the
  /// binding shows a document it does not know.
  @State private var session: ImageEditorSession
  @State private var quarterTurn: QuarterTurn?
  @State private var straightenAngle: CropEditingState.AdjustmentAngle?
  @State private var aspectRatioSelection: AspectRatioSelection
  @State private var isSelectingAspectRatio = false
  @State private var editingMode: ImageEditor.Mode = .crop
  @State private var localBlurState = LocalBlurState()
  @State private var adjustmentParameter: ImageEditor.Adjustment =
    .exposure
  @State private var resetAction = ImageEditorCanvas.ResetAction()
  @State private var rotateAction = ImageEditorCanvas.RotateAction()
  @State private var applyAction = ImageEditorCanvas.ApplyAction()
  @State private var adjustmentAngleCommitAction =
    ImageEditorCanvas.AdjustmentAngleCommitAction()

  init(
    document: Binding<ImageEditorDocument>,
    editingStack: EditingStack,
    options: ImageEditor.Options,
    localizedStrings: ImageEditor.LocalizedStrings,
    onDone: @escaping @MainActor () -> Void,
    onCancel: (@MainActor () -> Void)?
  ) {
    self._document = document
    self.editingStack = editingStack
    self.options = options
    self.localizedStrings = localizedStrings
    self.onDone = onDone
    self.onCancel = onCancel
    self._session = State(
      initialValue: ImageEditorSession(documentAtStart: document.wrappedValue)
    )

    switch options.aspectRatioOptions {
    case .fixed(let aspectRatio):
      self._aspectRatioSelection = State(
        initialValue: .init(aspectRatio: aspectRatio)
      )
    case .selectable:
      self._aspectRatioSelection = State(initialValue: .freeform)
    }
  }

  var body: some View {
    // Known from the image itself, before the editing source is prepared.
    let originalAspectRatio = PixelAspectRatio(document.image.pixelSize)
    let isLoaded = editingStack.loadedState != nil
    // Includes a slider value that is shown but not yet written.
    let displayedFeature = session.displayedFeature(of: document)
    let cancelAction: (() -> Void)? = onCancel == nil ? nil : { cancel() }
    let bottomControlHeight: CGFloat = 120
    let bottomControlMaxWidth: CGFloat = 560

    NavigationStack {
      ZStack {
        Color.black
          .ignoresSafeArea()

        VStack(spacing: 0) {
          CanvasHost(
            document: canvasDocumentBinding,
            displayedFeature: displayedFeature,
            editingStack: editingStack,
            mode: editingMode,
            localBlurState: localBlurState,
            quarterTurn: $quarterTurn,
            straightenAngle: $straightenAngle,
            lockedAspectRatio: lockedAspectRatioBinding(
              originalAspectRatio: originalAspectRatio
            ),
            resetAction: resetAction,
            rotateAction: rotateAction,
            applyAction: applyAction,
            adjustmentAngleCommitAction: adjustmentAngleCommitAction,
            editingTarget: editingMode.canvasTarget
          )
          .layoutPriority(1)

          ControlHost(
            mode: editingMode,
            originalAspectRatio: originalAspectRatio,
            aspectRatioSelection: aspectRatioSelection,
            localBlurState: localBlurState,
            filterPresets: options.filterPresets,
            filterPreviewBaseImage: editingStack.loadedState?.thumbnailImage,
            currentEffects: displayedFeature.effects,
            adjustmentParameter: adjustmentParameter,
            localizedStrings: localizedStrings,
            straightenAngle: straightenAngle,
            isSelectingAspectRatio: isSelectingAspectRatio,
            isLoaded: isLoaded,
            onSelectAspectRatio: selectAspectRatio,
            onSetStraightenAngle: setStraightenAngle,
            onCommitStraightenAngle: commitStraightenAngle,
            onSetBrushDiameter: setLocalBlurBrushDiameter,
            onClearLocalBlur: clearLocalBlur,
            onSelectFilterPreset: selectFilterPreset,
            onSelectAdjustmentParameter: selectAdjustmentParameter,
            onSetAdjustmentValue: previewAdjustmentValue,
            onEndAdjustmentValue: endAdjustmentValue
          )
          .frame(maxWidth: bottomControlMaxWidth)
          .frame(maxWidth: .infinity)
          .frame(height: bottomControlHeight)
        }
      }
      .safeAreaInset(edge: .bottom) {
        ModeToolbar(
          selection: editingMode,
          isLoaded: isLoaded,
          onSelect: selectMode
        )
      }
      .navigationTitle("")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
      .toolbar {
        EditorToolbar(
          resetTitle: localizedStrings.reset,
          cancelTitle: localizedStrings.cancel,
          doneTitle: localizedStrings.done,
          isLoaded: isLoaded,
          hasCropChanges: document.hasCropChanges(),
          // A failed preparation leaves nothing to edit; Done stays the
          // way out even when the host hides Cancel.
          isDoneEnabled: isLoaded || editingStack.didFailToPrepare,
          mode: editingMode,
          isSelectingAspectRatio: isSelectingAspectRatio,
          onRotate: rotate,
          onReset: reset,
          onToggleAspectRatio: toggleAspectRatioControl,
          onSelectMode: selectMode,
          onCancel: cancelAction,
          onDone: finish
        )
      }
      .foregroundStyle(.white)
      .task {
        editingStack.start()
      }
      .onChange(of: isAspectRatioControlAvailable) { _, isAvailable in
        if isAvailable == false {
          isSelectingAspectRatio = false
        }
      }
      .onChange(of: editingMode) { _, mode in
        if mode != .crop {
          isSelectingAspectRatio = false
        }
      }
      .onChange(of: document.feature) { _, _ in
        // The editor's own writes consume the live value first, so a change
        // here while a value is live came from outside (for example an undo
        // by the host). The document wins.
        session.discardLiveFeature()
      }
      .onChange(of: document) { _, document in
        // A document the session did not write (for example another
        // document of the same image) restarts it, so Cancel never writes
        // one document's start over another.
        session.noteDocument(document)
      }
      .accessibilityIdentifier("image-editor")
    }
    // ImageEditor is a dark, full-screen editor; keep system toolbar glass
    // resolved against dark traits even when the host app is in Light Mode.
    .preferredColorScheme(.dark)
    .environment(\.colorScheme, .dark)
  }

  private var isAspectRatioControlAvailable: Bool {
    switch options.aspectRatioOptions {
    case .selectable:
      return true
    case .fixed:
      return false
    }
  }

  private func rotate() {
    rotateAction()
  }

  private func reset() {
    resetAction()
  }

  private func toggleAspectRatioControl() {
    guard editingMode == .crop, isAspectRatioControlAvailable else {
      return
    }

    isSelectingAspectRatio.toggle()
  }

  private func selectAspectRatio(_ selection: AspectRatioSelection) {
    aspectRatioSelection = selection
  }

  private func setStraightenAngle(_ degrees: Double) {
    let angle = CropEditingState.AdjustmentAngle(degrees: degrees)

    guard straightenAngle != angle else {
      return
    }

    straightenAngle = angle
  }

  private func commitStraightenAngle(_ degrees: Double) {
    adjustmentAngleCommitAction(.init(degrees: degrees))
  }

  private func setLocalBlurBrushDiameter(_ diameter: CGFloat) {
    guard localBlurState.brushDiameter != diameter else {
      return
    }

    localBlurState.brushDiameter = diameter
  }

  private func selectMode(_ mode: ImageEditor.Mode) {
    guard editingMode != mode else {
      return
    }

    if editingMode == .crop {
      // Writes the crop guide's pending crop to the binding synchronously.
      applyAction()
    }

    // The next write commits this visit's work, so undo/redo steps at tool
    // granularity without a write that changes only the history.
    if let next = session.endToolVisit(of: document) {
      document = next
    }

    editingMode = mode
  }

  private func selectFilterPreset(_ preset: PresetFeature?) {
    write { $0.selectFilterPreset(preset) }
  }

  private func selectAdjustmentParameter(
    _ parameter: ImageEditor.Adjustment
  ) {
    guard adjustmentParameter != parameter else {
      return
    }
    adjustmentParameter = parameter
  }

  /// Shows a slider value while dragging; the document is written when the
  /// drag ends.
  private func previewAdjustmentValue(_ sliderValue: Double) {
    session.previewAdjustmentValue(
      sliderValue,
      parameter: adjustmentParameter,
      over: document
    )
  }

  /// Writes the slider value once, when the drag (or a reset) ends.
  private func endAdjustmentValue(_ sliderValue: Double) {
    previewAdjustmentValue(sliderValue)
    write()
  }

  private func clearLocalBlur() {
    write { $0.clearLocalBlur() }
  }

  private func finish() {
    // The crop guide's pending crop reaches the binding synchronously. The
    // last tool visit stays uncommitted: a commit alone would be a write
    // that changes nothing visible. The next edit commits it.
    applyAction()
    write()
    onDone()
  }

  private func cancel() {
    // One write back to the document the editor opened with, history
    // included, then the host dismisses.
    if let restored = session.documentForCancel(replacing: document) {
      document = restored
    }
    onCancel?()
  }

  /// Writes a completed operation to the binding as one write: a live
  /// slider value, then `change`, with the previous tool visit committed
  /// first when this is the visit's first write. Nothing is written when
  /// the feature is unchanged.
  private func write(
    _ change: (inout ImageEditorDocument) -> Void = { _ in }
  ) {
    if let next = session.document(after: document, change: change) {
      document = next
    }
  }

  /// The binding the canvas writes through: its changes go through the
  /// session like the controls' writes.
  private var canvasDocumentBinding: Binding<ImageEditorDocument> {
    Binding {
      document
    } set: { changed in
      if let next = session.document(afterCanvasChange: changed, over: document) {
        document = next
      }
    }
  }

  private func lockedAspectRatioBinding(
    originalAspectRatio: PixelAspectRatio?
  ) -> Binding<PixelAspectRatio?> {
    Binding {
      aspectRatioSelection.aspectRatio(originalAspectRatio: originalAspectRatio)
    } set: { aspectRatio in
      aspectRatioSelection.sync(
        aspectRatio: aspectRatio,
        originalAspectRatio: originalAspectRatio
      )
    }
  }

  private struct ModeToolbar: View {

    let selection: ImageEditor.Mode
    let isLoaded: Bool
    let onSelect: (ImageEditor.Mode) -> Void

    var body: some View {
      let body = HStack(spacing: 12) {
        ForEach(ImageEditor.Mode.allCases) { mode in
          _Button(
            mode: mode,
            isSelected: selection == mode,
            isEnabled: isLoaded
          ) {
            onSelect(mode)
          }
        }
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 8)

      if #available(iOS 26, *) {
        body
          .glassEffect(.regular.interactive())
      } else {
        body
      }
    }

    private struct _Button: View {

      let mode: ImageEditor.Mode
      let isSelected: Bool
      let isEnabled: Bool
      let action: () -> Void

      var body: some View {
        Button(action: action) {
          VStack(spacing: 3) {
            ZStack(alignment: .top) {
              Image(systemName: mode.systemImageName)
                .font(.system(size: 18, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .frame(width: 28, height: 28)
            }

            Text(mode.title)
              .font(
                .system(size: 11, weight: isSelected ? .semibold : .regular)
              )
              .lineLimit(1)
              .minimumScaleFactor(0.75)
          }
          .foregroundStyle(foregroundStyle)
          .frame(width: 48, height: 48)
        }
        .disabled(!isEnabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(mode.accessibilityLabel)
        .accessibilityValue(isSelected ? "selected" : "not selected")
        .accessibilityIdentifier(mode.accessibilityIdentifier)
      }

      private var foregroundStyle: Color {
        guard isEnabled else {
          return Color.white.opacity(0.22)
        }

        if isSelected {
          return .white
        } else {
          return Color.white.opacity(0.55)
        }
      }
    }

  }

}

extension ImageEditor {

  /// A top-level editing mode shown in the ImageEditor bottom toolbar.
  ///
  /// The mode controls which controls are displayed below the canvas and which
  /// interaction surface `ImageEditorCanvas` exposes. Future modes are represented
  /// here even before their controls are implemented so the UI tree can settle
  /// around the same routing model.
  enum Mode: CaseIterable, Equatable, Identifiable {
    case crop
    case localBlur
    case filters
    case adjust

    var id: Self { self }

    var title: String {
      switch self {
      case .crop:
        return "Crop"
      case .localBlur:
        return "Blur"
      case .filters:
        return "Filters"
      case .adjust:
        return "Adjust"
      }
    }

    var accessibilityLabel: String {
      switch self {
      case .crop:
        return "Crop"
      case .localBlur:
        return "Blur Masking"
      case .filters:
        return "Filters"
      case .adjust:
        return "Adjustments"
      }
    }

    var systemImageName: String {
      switch self {
      case .crop:
        return "crop"
      case .localBlur:
        return "paintbrush"
      case .filters:
        return "camera.filters"
      case .adjust:
        return "slider.horizontal.3"
      }
    }

    var accessibilityIdentifier: String {
      switch self {
      case .crop:
        return "image-editor.mode.crop"
      case .localBlur:
        return "image-editor.mode.local-blur"
      case .filters:
        return "image-editor.mode.filters"
      case .adjust:
        return "image-editor.mode.adjust"
      }
    }

    /// What `ImageEditorCanvas` gestures edit in this mode. Filters and
    /// Adjustments edit through controls below the canvas, so the canvas only
    /// views the output there.
    var canvasTarget: ImageEditorCanvas.Target? {
      switch self {
      case .crop:
        return .crop
      case .localBlur:
        return .localBlur
      case .filters, .adjust:
        return nil
      }
    }
  }
}

/// Mutable state for ImageEditor's first local-adjustment mode.
///
/// The brush diameter is stored in viewport points so the visible control reads
/// like a Photos-style tool; EditingCanvasView resolves it into image space.
private struct LocalBlurState: Equatable {
  var brushDiameter: CGFloat = 30
}

private struct CanvasHost: View {

  @Binding var document: ImageEditorDocument
  let displayedFeature: ImageEditorFeature
  let editingStack: EditingStack
  let mode: ImageEditor.Mode
  let localBlurState: LocalBlurState
  let quarterTurn: Binding<QuarterTurn?>
  let straightenAngle: Binding<CropEditingState.AdjustmentAngle?>
  let lockedAspectRatio: Binding<PixelAspectRatio?>
  let resetAction: ImageEditorCanvas.ResetAction
  let rotateAction: ImageEditorCanvas.RotateAction
  let applyAction: ImageEditorCanvas.ApplyAction
  let adjustmentAngleCommitAction: ImageEditorCanvas.AdjustmentAngleCommitAction
  let editingTarget: ImageEditorCanvas.Target?

  var body: some View {
    ImageEditorCanvas(
      document: $document,
      displayedFeature: displayedFeature,
      editingStack: editingStack,
      isGuideInteractionEnabled: mode == .crop
    )
    .quarterTurn(quarterTurn)
    .straightenAngle(straightenAngle)
    .lockedAspectRatio(lockedAspectRatio)
    .editingTarget(editingTarget)
    .brush(
      .init(diameter: .viewportPoints(localBlurState.brushDiameter))
    )
    .registerResetAction(resetAction)
    .registerRotateAction(rotateAction)
    .registerApplyAction(applyAction)
    .registerAdjustmentAngleCommitAction(adjustmentAngleCommitAction)
  }

}

private struct ControlHost: View {

  let mode: ImageEditor.Mode
  let originalAspectRatio: PixelAspectRatio?
  let aspectRatioSelection: AspectRatioSelection
  let localBlurState: LocalBlurState
  let filterPresets: [PresetFeature]
  let filterPreviewBaseImage: CIImage?
  let currentEffects: ImageEditorFeature.Effects?
  let adjustmentParameter: ImageEditor.Adjustment
  let localizedStrings: ImageEditor.LocalizedStrings
  let straightenAngle: CropEditingState.AdjustmentAngle?
  let isSelectingAspectRatio: Bool
  let isLoaded: Bool
  let onSelectAspectRatio: (AspectRatioSelection) -> Void
  let onSetStraightenAngle: (Double) -> Void
  let onCommitStraightenAngle: (Double) -> Void
  let onSetBrushDiameter: (CGFloat) -> Void
  let onClearLocalBlur: () -> Void
  let onSelectFilterPreset: (PresetFeature?) -> Void
  let onSelectAdjustmentParameter: (ImageEditor.Adjustment) -> Void
  let onSetAdjustmentValue: (Double) -> Void
  let onEndAdjustmentValue: (Double) -> Void

  var body: some View {
    Group {
      switch mode {
      case .crop:
        AdjustmentControl(
          originalAspectRatio: originalAspectRatio,
          aspectRatioSelection: aspectRatioSelection,
          localizedStrings: localizedStrings,
          straightenAngle: straightenAngle,
          isSelectingAspectRatio: isSelectingAspectRatio,
          isLoaded: isLoaded,
          onSelectAspectRatio: onSelectAspectRatio,
          onSetStraightenAngle: onSetStraightenAngle,
          onCommitStraightenAngle: onCommitStraightenAngle
        )

      case .localBlur:
        LocalBlurControl(
          brushDiameter: localBlurState.brushDiameter,
          isLoaded: isLoaded,
          onSetBrushDiameter: onSetBrushDiameter,
          onClearLocalBlur: onClearLocalBlur
        )

      case .filters:
        FilterControl(
          presets: filterPresets,
          baseImage: filterPreviewBaseImage,
          selectedPresetIdentifier: currentEffects?.preset?.identifier,
          localizedStrings: localizedStrings,
          isLoaded: isLoaded,
          onSelectPreset: onSelectFilterPreset
        )

      case .adjust:
        AdjustmentsControl(
          selection: adjustmentParameter,
          sliderValue: currentEffects.map {
            adjustmentParameter.sliderValue(in: $0)
          } ?? 0,
          isLoaded: isLoaded,
          onSelectParameter: onSelectAdjustmentParameter,
          onSetValue: onSetAdjustmentValue,
          onEndValue: onEndAdjustmentValue
        )
      }
    }
    .animation(.spring(response: 0.32, dampingFraction: 1), value: mode)
  }
}

private struct EditorToolbar: ToolbarContent {

  let resetTitle: String
  let cancelTitle: String
  let doneTitle: String
  let isLoaded: Bool
  let hasCropChanges: Bool
  let isDoneEnabled: Bool
  let mode: ImageEditor.Mode
  let isSelectingAspectRatio: Bool
  let onRotate: () -> Void
  let onReset: () -> Void
  let onToggleAspectRatio: () -> Void
  let onSelectMode: (ImageEditor.Mode) -> Void
  /// nil hides the Cancel button.
  let onCancel: (() -> Void)?
  let onDone: () -> Void

  var body: some ToolbarContent {
    if let onCancel {
      ToolbarItem(placement: .topBarLeading) {
        ToolbarTextButton(
          title: cancelTitle,
          accessibilityIdentifier: "image-editor.cancel",
          isEnabled: true,
          role: .normal,
          minWidth: nil,
          action: onCancel
        )
      }

      if #available(iOS 26.0, *) {
        ToolbarSpacer(.fixed, placement: .topBarLeading)
      }
    }

    ToolbarItem(placement: .topBarLeading) {
      switch mode {
      case .crop:
        ToolbarIconButton(
          systemName: "rotate.left",
          accessibilityLabel: "Rotate",
          accessibilityIdentifier: "image-editor.rotate",
          isEnabled: isLoaded && mode == .crop,
          isHighlighted: false,
          action: onRotate
        )
      case .adjust:
        EmptyView()
      case .localBlur:
        EmptyView()
      case .filters:
        EmptyView()
      }
    }

    ToolbarItem(placement: .principal) {
      if hasCropChanges && mode == .crop {
        ToolbarTextButton(
          title: resetTitle,
          accessibilityIdentifier: "image-editor.reset",
          isEnabled: isLoaded,
          role: .highlighted,
          minWidth: nil,
          action: onReset
        )
      } else {
        Color.clear
          .frame(width: 44, height: 44)
          .accessibilityHidden(true)
      }
    }

    ToolbarItem(placement: .topBarTrailing) {
      switch mode {
      case .crop:
        ToolbarIconButton(
          systemName: "aspectratio",
          accessibilityLabel: "Aspect Ratio",
          accessibilityIdentifier: "image-editor.aspect",
          isEnabled: isLoaded && mode == .crop,
          isHighlighted: isSelectingAspectRatio,
          action: onToggleAspectRatio
        )
      case .adjust:
        EmptyView()
      case .localBlur:
        EmptyView()
      case .filters:
        EmptyView()
      }
    }

    if #available(iOS 26.0, *) {
      ToolbarSpacer(.fixed, placement: .topBarTrailing)
    }

    ToolbarItem(placement: .topBarTrailing) {
      ToolbarTextButton(
        title: doneTitle,
        accessibilityIdentifier: "image-editor.done",
        isEnabled: isDoneEnabled,
        role: .highlighted,
        minWidth: nil,
        action: onDone
      )
    }

  }
}

private struct ToolbarIconButton: View {

  let systemName: String
  let accessibilityLabel: String
  let accessibilityIdentifier: String
  let isEnabled: Bool
  let isHighlighted: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 20, weight: .regular))
        .imageScale(.medium)
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(
          isHighlighted ? Color(uiColor: .systemYellow) : Color(white: 0.6)
        )
    }
    .disabled(!isEnabled)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityIdentifier(accessibilityIdentifier)
  }
}

private struct ToolbarTextButton: View {

  enum Role {
    case normal
    case highlighted
  }

  let title: String
  let accessibilityIdentifier: String
  let isEnabled: Bool
  let role: Role
  let minWidth: CGFloat?
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: fontSize))
        .foregroundStyle(foregroundStyle)
    }
    .disabled(!isEnabled)
    .accessibilityIdentifier(accessibilityIdentifier)
  }

  private var fontSize: CGFloat {
    switch role {
    case .normal:
      return 17
    case .highlighted:
      return 16
    }
  }

  private var foregroundStyle: Color {
    guard isEnabled else {
      return Color(uiColor: .darkGray)
    }

    switch role {
    case .normal:
      return .white
    case .highlighted:
      return Color(uiColor: .systemYellow)
    }
  }
}

private struct LocalBlurControl: View {

  let brushDiameter: CGFloat
  let isLoaded: Bool
  let onSetBrushDiameter: (CGFloat) -> Void
  let onClearLocalBlur: () -> Void

  var body: some View {
    HStack(spacing: 18) {
      Circle()
        .fill(Color.white.opacity(0.9))
        .frame(width: previewDiameter, height: previewDiameter)
        .frame(width: 52, height: 52)
        .background {
          Circle()
            .stroke(Color.white.opacity(0.24), lineWidth: 1)
        }
        .accessibilityHidden(true)

      BrightroomSteppedSlider(
        value: valueBinding,
        range: BrushSizeMetrics.sizeRange,
        stepCount: BrushSizeMetrics.stepCount,
        style: .imageEditorBrushSizeSlider,
        transform: { $0.rounded() },
        hapticIdentity: { value in
          Int(value.rounded()).isMultiple(of: 10)
            ? AnyHashable(Int(value.rounded())) : nil
        },
        onHaptic: {
          UIImpactFeedbackGenerator(style: .light).impactOccurred(
            intensity: 0.35
          )
        },
        topMarker: { _ in
          Color.clear
            .frame(width: 6, height: 6)
        },
        tick: { context in
          Capsule()
            .foregroundStyle(context.isMajor ? Color.primary : Color.secondary)
        }
      )
      .tint(.white)
      .frame(height: 50)
      .accessibilityLabel("Brush Size")

      ToolbarIconButton(
        systemName: "trash",
        accessibilityLabel: "Clear Blur Mask",
        accessibilityIdentifier: "image-editor.local-blur.clear",
        isEnabled: isLoaded,
        isHighlighted: false,
        action: onClearLocalBlur
      )
      .frame(width: 44, height: 52)
    }
    .padding(.horizontal, 24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .opacity(isLoaded ? 1 : 0.5)
    .disabled(!isLoaded)
    .environment(\.colorScheme, .dark)
  }

  private var previewDiameter: CGFloat {
    min(max(brushDiameter, 8), 42)
  }

  private var valueBinding: Binding<Double> {
    Binding(
      get: {
        min(
          max(
            Double(brushDiameter),
            BrushSizeMetrics.sizeRange.lowerBound
          ),
          BrushSizeMetrics.sizeRange.upperBound
        )
      },
      set: { value in
        let newDiameter = CGFloat(value.rounded())
        guard newDiameter != brushDiameter else {
          return
        }

        onSetBrushDiameter(newDiameter)
      }
    )
  }
}

private enum BrushSizeMetrics {
  static let minimumSize: Double = 8
  static let maximumSize: Double = 64
  static let sizeRange = minimumSize...maximumSize
  static let stepCount = Int(maximumSize - minimumSize)
}

/// Filter preset swatches. The selected preset is written to the document's
/// `effects.preset`.
///
/// Each chip previews the current image with that preset applied. The strip is
/// lazy: a chip renders its own swatch only as it first scrolls into view and
/// holds it in `@State`, which a `LazyHStack` retains for the chip's lifetime —
/// so scrolling never re-renders, only re-entering Filters mode does.
private struct FilterControl: View {

  /// On-screen edge length of a swatch.
  static let thumbnailPointSize: CGFloat = 56

  /// Scroll identity for the Original chip (preset chips use their identifier).
  private static let originalScrollID = "brightroom.filters.original"

  let presets: [PresetFeature]
  let baseImage: CIImage?
  let selectedPresetIdentifier: String?
  let localizedStrings: ImageEditor.LocalizedStrings
  let isLoaded: Bool
  let onSelectPreset: (PresetFeature?) -> Void

  /// The chip centered by `.scrollPosition` (also written back as the user
  /// scrolls). Driven to the selected chip whenever the selection changes.
  @State private var scrolledFilterID: String?

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      LazyHStack(spacing: 12) {
        FilterChip(
          title: localizedStrings.originalFilter,
          preset: nil,
          baseImage: baseImage,
          pointSize: Self.thumbnailPointSize,
          isSelected: selectedPresetIdentifier == nil,
          action: { onSelectPreset(nil) }
        )
        .id(Self.originalScrollID)
        .accessibilityIdentifier("image-editor.filters.original")

        ForEach(presets, id: \.identifier) { preset in
          FilterChip(
            title: preset.name,
            preset: preset,
            baseImage: baseImage,
            pointSize: Self.thumbnailPointSize,
            isSelected: selectedPresetIdentifier == preset.identifier,
            action: { onSelectPreset(preset) }
          )
          .id(preset.identifier)
          .accessibilityIdentifier("image-editor.filters.\(preset.identifier)")
        }
      }
      .scrollTargetLayout()
      .padding(.horizontal, 24)
      .frame(maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .scrollPosition(id: $scrolledFilterID, anchor: .center)
    .opacity(isLoaded ? 1 : 0.5)
    .disabled(!isLoaded)
    .environment(\.colorScheme, .dark)
    .accessibilityIdentifier("image-editor.filters")
    // Center the selected swatch on selection. ScrollView clamps at the ends, so
    // Original / the last filter just rest at the edge (Photos-like).
    .onChange(of: selectedPresetIdentifier) { _, newValue in
      withAnimation(.snappy) {
        scrolledFilterID = newValue ?? Self.originalScrollID
      }
    }
  }
}

/// A single filter swatch: a square preview thumbnail above the preset name.
///
/// The chip renders its own swatch when it appears (`.task`) into its `@State`,
/// computed once for the chip's lifetime. `preset == nil` is the no-filter
/// ("Original") swatch.
private struct FilterChip: View {

  let title: String
  let preset: PresetFeature?
  let baseImage: CIImage?
  let pointSize: CGFloat
  let isSelected: Bool
  let action: () -> Void

  @Environment(\.displayScale) private var displayScale
  @State private var image: UIImage?

  var body: some View {
    Button(action: action) {
      VStack(spacing: 6) {
        ZStack {
          if let image {
            Image(uiImage: image)
              .resizable()
              .scaledToFill()
          } else {
            Color.white.opacity(0.08)
          }
        }
        .frame(width: pointSize, height: pointSize)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
          // The dark drop shadow keeps the white ring legible on bright swatches
          // (Original / Mono / Noir on light photos), where a plain white border
          // would have no contrast against the image.
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.white, lineWidth: 2.5)
            .shadow(
              color: Color.black.opacity(isSelected ? 0.55 : 0),
              radius: 2
            )
            .opacity(isSelected ? 1 : 0)
        }
        .animation(.easeInOut(duration: 0.2), value: image != nil)

        Text(title)
          .font(.system(size: 11))
          .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.5))
          .lineLimit(1)
      }
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(isSelected ? "selected" : "not selected")
    .task(id: renderKey) {
      guard let baseImage else {
        image = nil
        return
      }
      let rendered = await FilterSwatch.render(
        base: baseImage,
        preset: preset,
        pointSize: pointSize,
        scale: displayScale
      )
      guard !Task.isCancelled else { return }
      image = rendered
    }
  }

  /// Re-render only when the source thumbnail, the preset, or the scale changes.
  private var renderKey: RenderKey {
    RenderKey(
      baseImageID: baseImage.map(ObjectIdentifier.init),
      presetIdentifier: preset?.identifier,
      scale: displayScale
    )
  }

  private struct RenderKey: Equatable {
    let baseImageID: ObjectIdentifier?
    let presetIdentifier: String?
    let scale: CGFloat
  }
}

/// Parameter selector plus value slider for ImageEditor's Adjust mode.
private struct AdjustmentsControl: View {

  let selection: ImageEditor.Adjustment
  let sliderValue: Double
  let isLoaded: Bool
  let onSelectParameter: (ImageEditor.Adjustment) -> Void
  /// Called for each value while dragging.
  let onSetValue: (Double) -> Void
  /// Called once when a drag, an accessibility step, or a reset ends.
  let onEndValue: (Double) -> Void

  var body: some View {
    VStack(spacing: 4) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 16) {
          ForEach(ImageEditor.Adjustment.allCases) { parameter in
            AdjustmentButton(
              parameter: parameter,
              isSelected: parameter == selection,
              action: { onSelectParameter(parameter) }
            )
          }
        }
        .padding(.horizontal, 24)
      }
      .frame(height: 56)

      BrightroomSteppedSlider(
        value: valueBinding,
        range: selection.sliderRange,
        stepCount: Int(
          (selection.sliderRange.upperBound - selection.sliderRange.lowerBound)
            / 4
        ),
        style: .imageEditorAdjustmentSlider,
        resetValue: 0,
        snapsToTicksOnEditingEnd: false,
        transform: { $0.rounded() },
        hapticIdentity: { value in
          let step = Int(value.rounded())
          return step.isMultiple(of: 25) ? AnyHashable(step) : nil
        },
        onHaptic: {
          UIImpactFeedbackGenerator(style: .light).impactOccurred(
            intensity: 0.35
          )
        },
        onEditingEnded: { value in
          onEndValue(value.rounded())
        },
        topMarker: { context in
          Circle()
            .frame(width: 6, height: 6)
            .opacity(context.isZero && sliderValue != 0 ? 1 : 0)
            .animation(.spring, value: sliderValue == 0)
        },
        tick: { context in
          Capsule()
            .foregroundStyle(context.isMajor ? Color.primary : Color.secondary)
        }
      )
      .id(selection)
      .tint(.white)
      .frame(height: 44)
      .accessibilityLabel(selection.title)
      .padding(.horizontal, 24)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .opacity(isLoaded ? 1 : 0.5)
    .disabled(!isLoaded)
    .environment(\.colorScheme, .dark)
    .accessibilityIdentifier("image-editor.adjust")
  }

  private var valueBinding: Binding<Double> {
    Binding(
      get: { sliderValue },
      set: { newValue in
        let rounded = newValue.rounded()
        guard rounded != sliderValue else {
          return
        }

        onSetValue(rounded)
      }
    )
  }
}

private struct AdjustmentButton: View {

  let parameter: ImageEditor.Adjustment
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(spacing: 3) {
        Image(systemName: parameter.systemImageName)
          .font(.system(size: 17, weight: .regular))
          .symbolRenderingMode(.monochrome)
          .frame(width: 30, height: 22)

        Text(parameter.title)
          .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
          .lineLimit(1)
          .minimumScaleFactor(0.7)
      }
      .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.55))
      .frame(width: 64, height: 48)
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(parameter.title)
    .accessibilityValue(isSelected ? "selected" : "not selected")
    .accessibilityIdentifier(parameter.accessibilityIdentifier)
  }
}

private struct AdjustmentControl: View {

  let originalAspectRatio: PixelAspectRatio?
  let aspectRatioSelection: AspectRatioSelection
  let localizedStrings: ImageEditor.LocalizedStrings
  let straightenAngle: CropEditingState.AdjustmentAngle?
  let isSelectingAspectRatio: Bool
  let isLoaded: Bool
  let onSelectAspectRatio: (AspectRatioSelection) -> Void
  let onSetStraightenAngle: (Double) -> Void
  let onCommitStraightenAngle: (Double) -> Void

  var body: some View {
    Group {
      if isSelectingAspectRatio, let originalAspectRatio {
        AspectRatioPicker(
          originalAspectRatio: originalAspectRatio,
          selection: aspectRatioSelection,
          localizedStrings: localizedStrings,
          onSelect: onSelectAspectRatio
        )
        .transition(.opacity)
      } else {
        StraightenSlider(
          value: straightenAngle?.degrees ?? 0,
          isEnabled: isLoaded,
          onChange: onSetStraightenAngle,
          onEditingEnded: onCommitStraightenAngle
        )
        .transition(.opacity)
      }
    }
    .animation(
      .spring(response: 0.35, dampingFraction: 1),
      value: isSelectingAspectRatio
    )
  }
}

private struct StraightenSlider: View {

  let value: Double
  let isEnabled: Bool
  let onChange: (Double) -> Void
  let onEditingEnded: (Double) -> Void

  var body: some View {
    BrightroomSteppedSlider(
      value: valueBinding,
      range: -45...45,
      stepCount: 90,
      style: .imageEditorRotationSlider,
      resetValue: 0,
      snapsToTicksOnEditingEnd: false,
      transform: { source in
        if (-StraightenSliderMetrics
          .neutralDeadZoneDegrees...StraightenSliderMetrics
          .neutralDeadZoneDegrees).contains(source)
        {
          return 0
        }

        return source
      },
      hapticIdentity: { value in
        let degree = Int(value.rounded(.toNearestOrEven))
        return degree.isMultiple(of: 5) ? AnyHashable(degree) : nil
      },
      onHaptic: {
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.4)
      },
      onEditingEnded: onEditingEnded,
      topMarker: { context in
        Circle()
          .frame(width: 6, height: 6)
          .opacity(context.isZero && value != 0 ? 1 : 0)
          .animation(.spring, value: value == 0)
      },
      tick: { context in
        RoundedRectangle(cornerRadius: 8)
          .foregroundStyle(context.isMajor ? Color.primary : Color.secondary)
      }
    )
    .tint(.white)
    .frame(height: 50)
    .padding(.horizontal, 24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .opacity(isEnabled ? 1 : 0.5)
    .disabled(!isEnabled)
    .accessibilityLabel("Rotation")
    .environment(\.colorScheme, .dark)
  }

  private var valueBinding: Binding<Double> {
    Binding(
      get: { value },
      set: { newValue in
        guard newValue != value else {
          return
        }

        onChange(newValue)
      }
    )
  }
}

private enum StraightenSliderMetrics {
  static let neutralDeadZoneDegrees: Double = 0.5
}

extension BrightroomSteppedSliderStyle {
  fileprivate static let imageEditorRotationSlider =
    BrightroomSteppedSliderStyle(
      tickWidth: 2,
      tickSpacing: 4,
      tickHeight: 10,
      activeTickWidth: 3,
      activeTickHeight: 18,
      majorTickInterval: 5
    )

  fileprivate static let imageEditorAdjustmentSlider =
    BrightroomSteppedSliderStyle(
      tickWidth: 2,
      tickSpacing: 4,
      tickHeight: 10,
      activeTickWidth: 3,
      activeTickHeight: 18,
      majorTickInterval: 5
    )

  fileprivate static let imageEditorBrushSizeSlider =
    BrightroomSteppedSliderStyle(
      tickWidth: 2,
      tickSpacing: 4,
      tickHeight: 10,
      activeTickWidth: 3,
      activeTickHeight: 18,
      majorTickInterval: 8
    )
}

extension BrightroomSteppedSliderTickContext {
  fileprivate var isZero: Bool {
    abs(value) < 0.000_001
  }
}

private enum AspectRatioSelection: Equatable {

  case freeform
  case original(AspectRatioDirection)
  case ratio(PixelAspectRatio)

  init(aspectRatio: PixelAspectRatio?) {
    if let aspectRatio {
      self = .ratio(aspectRatio)
    } else {
      self = .freeform
    }
  }

  var isFreeform: Bool {
    self == .freeform
  }

  var isOriginal: Bool {
    if case .original = self {
      return true
    } else {
      return false
    }
  }

  func isRatio(_ ratio: PixelAspectRatio) -> Bool {
    if case .ratio(let selectedRatio) = self {
      return selectedRatio == ratio
    } else {
      return false
    }
  }

  func aspectRatio(originalAspectRatio: PixelAspectRatio?) -> PixelAspectRatio?
  {
    switch self {
    case .freeform:
      return nil
    case .original(let direction):
      return originalAspectRatio.map { direction.orient($0) }
    case .ratio(let aspectRatio):
      return aspectRatio
    }
  }

  func direction(originalAspectRatio: PixelAspectRatio?)
    -> AspectRatioDirection?
  {
    switch self {
    case .freeform:
      return nil
    case .original(let direction):
      return direction
    case .ratio(let aspectRatio):
      return AspectRatioDirection(aspectRatio)
    }
  }

  func withDirection(
    _ direction: AspectRatioDirection,
    originalAspectRatio: PixelAspectRatio?
  ) -> Self {
    switch self {
    case .freeform:
      return .freeform
    case .original:
      return .original(direction)
    case .ratio(let aspectRatio):
      if AspectRatioDirection(aspectRatio) == direction {
        return self
      } else {
        return .ratio(aspectRatio.swapped())
      }
    }
  }

  mutating func sync(
    aspectRatio: PixelAspectRatio?,
    originalAspectRatio: PixelAspectRatio?
  ) {
    guard
      self.aspectRatio(originalAspectRatio: originalAspectRatio) != aspectRatio
    else {
      return
    }

    if case .original = self, let aspectRatio, let originalAspectRatio {
      if aspectRatio == originalAspectRatio {
        self = .original(AspectRatioDirection(originalAspectRatio))
        return
      }

      let swappedOriginalAspectRatio = originalAspectRatio.swapped()
      if aspectRatio == swappedOriginalAspectRatio {
        self = .original(
          AspectRatioDirection(swappedOriginalAspectRatio)
        )
        return
      }
    }

    self = .init(aspectRatio: aspectRatio)
  }
}

private struct AspectRatioPicker: View {

  let originalAspectRatio: PixelAspectRatio?
  let selection: AspectRatioSelection
  let localizedStrings: ImageEditor.LocalizedStrings
  let onSelect: (AspectRatioSelection) -> Void

  var body: some View {
    VStack(spacing: 24) {
      HStack(spacing: 18) {
        AspectRatioDirectionButton(
          direction: .vertical,
          selectedDirection: selectedDirection,
          isEnabled: canSelectDirection,
          onSelect: selectDirection
        )

        AspectRatioDirectionButton(
          direction: .horizontal,
          selectedDirection: selectedDirection,
          isEnabled: canSelectDirection,
          onSelect: selectDirection
        )
      }
      .frame(height: 28)

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 12) {
          if originalAspectRatio != nil {
            AspectRatioButton(
              title: localizedStrings.originalAspectRatio,
              isSelected: selection.isOriginal
            ) {
              onSelect(.original(selectedDirection))
            }
            .accessibilityIdentifier("image-editor.aspect.original")
          }

          AspectRatioButton(
            title: localizedStrings.freeformAspectRatio,
            isSelected: selection.isFreeform
          ) {
            onSelect(.freeform)
          }
          .accessibilityIdentifier("image-editor.aspect.freeform")

          AspectRatioButton(
            title: localizedStrings.squareAspectRatio,
            isSelected: selection.isRatio(.square)
          ) {
            onSelect(.ratio(.square))
          }
          .accessibilityIdentifier("image-editor.aspect.square")

          ForEach(Self.horizontalRectangleAspectRatios) { ratio in
            let displayedRatio = displayedRatio(for: ratio)
            let minimizedDisplayedRatio = displayedRatio._minimized()

            AspectRatioButton(
              title:
                "\(Int(minimizedDisplayedRatio.width)):\(Int(minimizedDisplayedRatio.height))",
              isSelected: selection.isRatio(minimizedDisplayedRatio)
            ) {
              onSelect(.ratio(minimizedDisplayedRatio))
            }
            .accessibilityIdentifier(
              "image-editor.aspect.\(Int(minimizedDisplayedRatio.width))x\(Int(minimizedDisplayedRatio.height))"
            )
          }
        }
        .padding(.horizontal, 24)
      }
    }
  }

  private var selectedDirection: AspectRatioDirection {
    selection.direction(originalAspectRatio: originalAspectRatio)
      ?? originalDirection
  }

  private var originalDirection: AspectRatioDirection {
    originalAspectRatio.map(AspectRatioDirection.init) ?? .horizontal
  }

  private var canSelectDirection: Bool {
    guard
      let selectedAspectRatio = selection.aspectRatio(
        originalAspectRatio: originalAspectRatio
      ), selectedAspectRatio != .square
    else {
      return false
    }

    return true
  }

  private func displayedRatio(for horizontalRatio: PixelAspectRatio)
    -> PixelAspectRatio
  {
    switch selectedDirection {
    case .horizontal:
      return horizontalRatio
    case .vertical:
      return horizontalRatio.swapped()
    }
  }

  private func selectDirection(_ direction: AspectRatioDirection) {
    guard canSelectDirection, selectedDirection != direction else {
      return
    }

    onSelect(
      selection.withDirection(
        direction,
        originalAspectRatio: originalAspectRatio
      )
    )
  }

  private static let horizontalRectangleAspectRatios: [PixelAspectRatio] = [
    .init(width: 16, height: 9),
    .init(width: 10, height: 8),
    .init(width: 7, height: 5),
    .init(width: 4, height: 3),
    .init(width: 5, height: 3),
    .init(width: 3, height: 2),
  ]
}

private struct AspectRatioButton: View {

  let title: String
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 12))
        .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.5))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background {
          Capsule()
            .fill(Color.white.opacity(0.5))
            .opacity(isSelected ? 1 : 0)
        }
    }
    .buttonStyle(.plain)
    .accessibilityValue(isSelected ? "selected" : "not selected")
  }
}

private struct AspectRatioDirectionButton: View {

  let direction: AspectRatioDirection
  let selectedDirection: AspectRatioDirection
  let isEnabled: Bool
  let onSelect: (AspectRatioDirection) -> Void

  var body: some View {
    Button {
      onSelect(direction)
    } label: {
      ZStack {
        RoundedRectangle(cornerRadius: 4)
          .fill(
            isSelected && isEnabled
              ? Color(white: 0.6) : Color.black.opacity(0.6)
          )

        RoundedRectangle(cornerRadius: 4)
          .stroke(Color(white: 0.6).opacity(isEnabled ? 1 : 0.3), lineWidth: 1)

        if isSelected && isEnabled {
          Image(systemName: "checkmark")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Color.black.opacity(0.8))
        }
      }
      .frame(width: size.width, height: size.height)
      .opacity(isEnabled ? 1 : 0.5)
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(direction.accessibilityLabel)
    .accessibilityValue(isSelected ? "selected" : "not selected")
    .accessibilityIdentifier(direction.accessibilityIdentifier)
  }

  private var isSelected: Bool {
    selectedDirection == direction
  }

  private var size: CGSize {
    switch direction {
    case .horizontal:
      return .init(width: 28, height: 18)
    case .vertical:
      return .init(width: 18, height: 28)
    }
  }
}

private enum AspectRatioDirection {
  case vertical
  case horizontal

  init(_ aspectRatio: PixelAspectRatio) {
    if aspectRatio.height > aspectRatio.width {
      self = .vertical
    } else {
      self = .horizontal
    }
  }

  func orient(_ aspectRatio: PixelAspectRatio) -> PixelAspectRatio {
    if AspectRatioDirection(aspectRatio) == self {
      return aspectRatio
    } else {
      return aspectRatio.swapped()
    }
  }

  var accessibilityLabel: String {
    switch self {
    case .vertical:
      return "Vertical"
    case .horizontal:
      return "Horizontal"
    }
  }

  var accessibilityIdentifier: String {
    switch self {
    case .vertical:
      return "image-editor.aspect.direction.vertical"
    case .horizontal:
      return "image-editor.aspect.direction.horizontal"
    }
  }
}

#if DEBUG

  #Preview("ImageEditor Checkerboard") {
    PreviewHost()
  }

  #Preview("Toolbar Groups") {

    NavigationStack {
      Color.blue
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) {
            Button("Hello") {

            }
          }
          ToolbarItem(placement: .topBarTrailing) {
            Button("Hello") {

            }
          }
        }
    }

  }

  private struct PreviewHost: View {

    // The document holds the edit and its history, so it lives with the view.
    @State private var document = ImageEditorDocument(
      image: SourceImage(image: PreviewFixtures.makeCheckerboardImage())
    )

    var body: some View {
      ImageEditor(
        document: $document,
        onDone: {},
        onCancel: {}
      )
    }
  }

  private enum PreviewFixtures {

    static func makeCheckerboardImage() -> UIImage {
      let size = CGSize(width: 1400, height: 900)
      let cellSize: CGFloat = 100
      let format = UIGraphicsImageRendererFormat()
      format.scale = 1

      return UIGraphicsImageRenderer(size: size, format: format).image {
        context in
        let cgContext = context.cgContext
        let canvasRect = CGRect(origin: .zero, size: size)
        UIColor.systemBackground.setFill()
        cgContext.fill(canvasRect)

        let columnCount = Int(ceil(size.width / cellSize))
        let rowCount = Int(ceil(size.height / cellSize))

        for row in 0..<rowCount {
          for column in 0..<columnCount {
            let rect = CGRect(
              x: CGFloat(column) * cellSize,
              y: CGFloat(row) * cellSize,
              width: cellSize,
              height: cellSize
            )
            let color =
              (row + column).isMultiple(of: 2)
              ? UIColor(white: 0.86, alpha: 1)
              : UIColor(white: 0.98, alpha: 1)
            color.setFill()
            cgContext.fill(rect)
          }
        }

        UIColor.black.withAlphaComponent(0.22).setStroke()
        cgContext.setLineWidth(2)

        for column in 0...columnCount {
          let x = CGFloat(column) * cellSize
          cgContext.move(to: CGPoint(x: x, y: 0))
          cgContext.addLine(to: CGPoint(x: x, y: size.height))
        }

        for row in 0...rowCount {
          let y = CGFloat(row) * cellSize
          cgContext.move(to: CGPoint(x: 0, y: y))
          cgContext.addLine(to: CGPoint(x: size.width, y: y))
        }

        cgContext.strokePath()
      }
    }
  }
#endif
