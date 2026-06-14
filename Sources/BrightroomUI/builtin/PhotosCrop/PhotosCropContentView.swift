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

import SwiftUI
import UIKit

import BrightroomEngine
import BrightroomParametric

struct PhotosCropContentView: View {

  let editingStack: EditingStack
  let options: SwiftUIPhotosCropView.Options
  let localizedStrings: SwiftUIPhotosCropView.LocalizedStrings
  let onDone: @MainActor () -> Void
  let onCancel: @MainActor () -> Void

  @State private var rotation: CropEditingState.Rotation?
  @State private var adjustmentAngle: CropEditingState.AdjustmentAngle?
  @State private var aspectRatioSelection: PhotosCropAspectRatioSelection
  @State private var isSelectingAspectRatio = false
  @State private var editingMode: PhotosCropEditingMode = .crop
  @State private var blurMaskingState = PhotosCropBlurMaskingState()
  @State private var adjustmentParameter: PhotosCropAdjustmentParameter = .exposure
  @State private var resetAction = SwiftUICropView.ResetAction()
  @State private var rotateAction = SwiftUICropView.RotateAction()
  @State private var applyAction = SwiftUICropView.ApplyAction()
  @State private var adjustmentAngleCommitAction = SwiftUICropView.AdjustmentAngleCommitAction()

  init(
    editingStack: EditingStack,
    options: SwiftUIPhotosCropView.Options,
    localizedStrings: SwiftUIPhotosCropView.LocalizedStrings,
    onDone: @escaping @MainActor () -> Void,
    onCancel: @escaping @MainActor () -> Void
  ) {
    self.editingStack = editingStack
    self.options = options
    self.localizedStrings = localizedStrings
    self.onDone = onDone
    self.onCancel = onCancel

    switch options.aspectRatioOptions {
    case .fixed(let aspectRatio):
      self._aspectRatioSelection = State(initialValue: .init(aspectRatio: aspectRatio))
    case .selectable:
      self._aspectRatioSelection = State(initialValue: .freeform)
    }
  }

  var body: some View {
    let loadedState = editingStack.loadedState
    let originalAspectRatio = loadedState.map { PixelAspectRatio($0.imageSize) }
    let isLoaded = loadedState != nil
    let bottomControlHeight: CGFloat = 120
    let bottomControlMaxWidth: CGFloat = 560

    NavigationStack {
      ZStack {
        Color.black
          .ignoresSafeArea()

        VStack(spacing: 0) {
          PhotosCropCanvasHost(
            editingStack: editingStack,
            mode: editingMode,
            blurMaskingState: blurMaskingState,
            rotation: $rotation,
            adjustmentAngle: $adjustmentAngle,
            croppingAspectRatio: croppingAspectRatioBinding(originalAspectRatio: originalAspectRatio),
            resetAction: resetAction,
            rotateAction: rotateAction,
            applyAction: applyAction,
            adjustmentAngleCommitAction: adjustmentAngleCommitAction
          )
          .layoutPriority(1)

          PhotosCropControlHost(
            mode: editingMode,
            originalAspectRatio: originalAspectRatio,
            aspectRatioSelection: aspectRatioSelection,
            blurMaskingState: blurMaskingState,
            filterPresets: options.filterPresets,
            currentEffects: loadedState?.currentEdit.effects,
            adjustmentParameter: adjustmentParameter,
            localizedStrings: localizedStrings,
            adjustmentAngle: adjustmentAngle,
            isSelectingAspectRatio: isSelectingAspectRatio,
            isLoaded: isLoaded,
            onSelectAspectRatio: selectAspectRatio,
            onSetAdjustmentAngle: setAdjustmentAngle,
            onCommitAdjustmentAngle: commitAdjustmentAngle,
            onSetBrushDiameter: setBlurMaskingBrushDiameter,
            onClearBlurMask: clearBlurMaskingLayer,
            onSelectFilterPreset: selectFilterPreset,
            onSelectAdjustmentParameter: selectAdjustmentParameter,
            onSetAdjustmentValue: setAdjustmentValue
          )
          .frame(maxWidth: bottomControlMaxWidth)
          .frame(maxWidth: .infinity)
          .frame(height: bottomControlHeight)
        }
      }
      .navigationTitle("")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
      .toolbar {
        PhotosCropToolbar(
          resetTitle: localizedStrings.button_reset_title,
          cancelTitle: localizedStrings.button_cancel_title,
          doneTitle: localizedStrings.button_done_title,
          isLoaded: isLoaded,
          hasCropChanges: hasCropChanges(loadedState: loadedState),
          isDoneEnabled: isLoaded,
          mode: editingMode,
          isSelectingAspectRatio: isSelectingAspectRatio,
          onRotate: rotate,
          onReset: reset,
          onToggleAspectRatio: toggleAspectRatioControl,
          onSelectMode: selectMode,
          onCancel: onCancel,
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
      .accessibilityIdentifier("photos.crop")
    }
    // PhotosCrop is a dark, full-screen editor; keep system toolbar glass
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

  /// Whether the crop differs from what the Reset button would restore.
  ///
  /// Reset only restores the crop (`CropEditingState.makeInitial()`), so its
  /// visibility tracks crop state alone — painting a blur mask must not
  /// surface a Reset button that would do nothing.
  ///
  /// The extent comparison tolerates sub-pixel drift because leaving Crop
  /// mode re-commits the guide's laid-out geometry, which can differ from
  /// the document crop by a fraction of a pixel.
  private func hasCropChanges(loadedState: EditingStack.Loaded?) -> Bool {
    guard let loadedState else {
      return false
    }

    // Lower the stored crop into the UI working model so the comparison stays in
    // the same y-down display space the reset (`makeInitial`) produces.
    let crop = CropEditingState(
      cropFeature: loadedState.currentEdit.crop,
      imageSize: loadedState.currentEdit.imageSize
    )
    let initial = crop.makeInitial()
    let tolerance: CGFloat = 1

    return crop.rotation != initial.rotation
      || abs(crop.adjustmentAngle.radians - initial.adjustmentAngle.radians) > 0.0001
      || abs(crop.cropExtent.minX - initial.cropExtent.minX) > tolerance
      || abs(crop.cropExtent.minY - initial.cropExtent.minY) > tolerance
      || abs(crop.cropExtent.width - initial.cropExtent.width) > tolerance
      || abs(crop.cropExtent.height - initial.cropExtent.height) > tolerance
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

  private func selectAspectRatio(_ selection: PhotosCropAspectRatioSelection) {
    aspectRatioSelection = selection
  }

  private func setAdjustmentAngle(_ degrees: Double) {
    let angle = CropEditingState.AdjustmentAngle(degrees: degrees)

    guard adjustmentAngle != angle else {
      return
    }

    adjustmentAngle = angle
  }

  private func commitAdjustmentAngle(_ degrees: Double) {
    adjustmentAngleCommitAction(.init(degrees: degrees))
  }

  private func setBlurMaskingBrushDiameter(_ diameter: CGFloat) {
    guard blurMaskingState.brushDiameter != diameter else {
      return
    }

    blurMaskingState.brushDiameter = diameter
  }

  private func selectMode(_ mode: PhotosCropEditingMode) {
    guard mode.isAvailable, editingMode != mode else {
      return
    }

    // Leaving a tool commits its work as a version, so undo/redo steps at
    // tool granularity. The stack snapshots the whole feature-list document.
    if editingStack.loadedState?.hasUncommitedChanges == true {
      editingStack.takeSnapshot()
    }

    editingMode = mode
  }

  /// Writes the selected preset into the global-effects feature node.
  private func selectFilterPreset(_ preset: PresetFeature?) {
    editingStack.updateGlobalEffectsFeature { effects in
      guard effects.first(of: PresetFeature.self)?.identifier != preset?.identifier else {
        return
      }
      effects.set(preset, insertionIndex: PhotosCropEffectOrder.insertionIndex(for: PresetFeature.self))
    }
  }

  private func selectAdjustmentParameter(_ parameter: PhotosCropAdjustmentParameter) {
    guard adjustmentParameter != parameter else {
      return
    }
    adjustmentParameter = parameter
  }

  /// Writes a slider value for the selected parameter into the global-effects
  /// feature node.
  private func setAdjustmentValue(_ sliderValue: Double) {
    editingStack.updateGlobalEffectsFeature { effects in
      adjustmentParameter.apply(sliderValue: sliderValue, to: &effects)
    }
  }

  private func clearBlurMaskingLayer() {
    let blurIdentity = CropViewMaskingDefaults.blurEffectPipeline.editingCanvasEffectIdentity
    let localAdjustments = editingStack.loadedState?.currentEdit.localAdjustments ?? []
    let remainingLocalAdjustments = localAdjustments.filter {
      $0.effectPipeline.editingCanvasEffectIdentity != blurIdentity
    }

    guard remainingLocalAdjustments != localAdjustments else {
      return
    }

    editingStack.set(localAdjustments: remainingLocalAdjustments)
  }

  private func finish() {
    applyAction()
    if editingStack.loadedState?.hasUncommitedChanges == true {
      editingStack.takeSnapshot()
    }
    onDone()
  }

  private func croppingAspectRatioBinding(originalAspectRatio: PixelAspectRatio?) -> Binding<PixelAspectRatio?> {
    Binding {
      aspectRatioSelection.aspectRatio(originalAspectRatio: originalAspectRatio)
    } set: { aspectRatio in
      aspectRatioSelection.sync(
        aspectRatio: aspectRatio,
        originalAspectRatio: originalAspectRatio
      )
    }
  }

}

/// A top-level editing mode shown in the PhotosCrop bottom toolbar.
///
/// The mode controls which controls are displayed below the canvas and which
/// interaction surface `SwiftUICropView` exposes. Future modes are represented
/// here even before their controls are implemented so the UI tree can settle
/// around the same routing model.
private enum PhotosCropEditingMode: CaseIterable, Equatable, Identifiable {
  case crop
  case blurMasking
  case filters
  case adjustments

  var id: Self { self }

  var title: String {
    switch self {
    case .crop:
      return "Crop"
    case .blurMasking:
      return "Blur"
    case .filters:
      return "Filters"
    case .adjustments:
      return "Adjust"
    }
  }

  var accessibilityLabel: String {
    switch self {
    case .crop:
      return "Crop"
    case .blurMasking:
      return "Blur Masking"
    case .filters:
      return "Filters"
    case .adjustments:
      return "Adjustments"
    }
  }

  var systemImageName: String {
    switch self {
    case .crop:
      return "crop"
    case .blurMasking:
      return "paintbrush"
    case .filters:
      return "camera.filters"
    case .adjustments:
      return "slider.horizontal.3"
    }
  }

  var accessibilityIdentifier: String {
    switch self {
    case .crop:
      return "photos.crop.mode.crop"
    case .blurMasking:
      return "photos.crop.mode.blur-masking"
    case .filters:
      return "photos.crop.mode.filters"
    case .adjustments:
      return "photos.crop.mode.adjustments"
    }
  }

  var isAvailable: Bool {
    switch self {
    case .crop, .blurMasking, .filters, .adjustments:
      return true
    }
  }
}

/// Mutable state for PhotosCrop's first local-adjustment mode.
///
/// The brush diameter is stored in viewport points so the visible control reads
/// like a Photos-style tool; CropView resolves it into image space.
private struct PhotosCropBlurMaskingState: Equatable {
  var brushDiameter: CGFloat = 30
}

private struct PhotosCropCanvasHost: View {

  let editingStack: EditingStack
  let mode: PhotosCropEditingMode
  let blurMaskingState: PhotosCropBlurMaskingState
  let rotation: Binding<CropEditingState.Rotation?>
  let adjustmentAngle: Binding<CropEditingState.AdjustmentAngle?>
  let croppingAspectRatio: Binding<PixelAspectRatio?>
  let resetAction: SwiftUICropView.ResetAction
  let rotateAction: SwiftUICropView.RotateAction
  let applyAction: SwiftUICropView.ApplyAction
  let adjustmentAngleCommitAction: SwiftUICropView.AdjustmentAngleCommitAction

  var body: some View {
    SwiftUICropView(
      editingStack: editingStack,
      isGuideInteractionEnabled: mode == .crop,
      isAutoApplyEditingStackEnabled: true
    )
    .rotation(rotation)
    .adjustmentAngle(adjustmentAngle)
    .croppingAspectRatio(croppingAspectRatio)
    .featureFocus(featureFocus)
    .maskingBrush(.init(diameter: .viewportPoints(blurMaskingState.brushDiameter)))
    .strokeSmoothing(.init())
    .registerResetAction(resetAction)
    .registerRotateAction(rotateAction)
    .registerApplyAction(applyAction)
    .registerAdjustmentAngleCommitAction(adjustmentAngleCommitAction)
  }

  /// The FeatureTree focus for the current editing mode.
  ///
  /// Every mode views the evaluated output (`.output`); what changes is the
  /// adjustment point. Crop edits the final crop node, blur masking paints a
  /// pre-crop local adjustment (CropView derives the blur seed from the
  /// current crop), and filters/adjustments edit the global effects node
  /// through controls outside the canvas.
  private var featureFocus: CropViewFeatureFocus {
    switch mode {
    case .crop:
      return .finalCrop
    case .blurMasking:
      return .masking()
    case .filters, .adjustments:
      return .output
    }
  }
}

private struct PhotosCropControlHost: View {

  let mode: PhotosCropEditingMode
  let originalAspectRatio: PixelAspectRatio?
  let aspectRatioSelection: PhotosCropAspectRatioSelection
  let blurMaskingState: PhotosCropBlurMaskingState
  let filterPresets: [PresetFeature]
  let currentEffects: EffectPipeline?
  let adjustmentParameter: PhotosCropAdjustmentParameter
  let localizedStrings: SwiftUIPhotosCropView.LocalizedStrings
  let adjustmentAngle: CropEditingState.AdjustmentAngle?
  let isSelectingAspectRatio: Bool
  let isLoaded: Bool
  let onSelectAspectRatio: (PhotosCropAspectRatioSelection) -> Void
  let onSetAdjustmentAngle: (Double) -> Void
  let onCommitAdjustmentAngle: (Double) -> Void
  let onSetBrushDiameter: (CGFloat) -> Void
  let onClearBlurMask: () -> Void
  let onSelectFilterPreset: (PresetFeature?) -> Void
  let onSelectAdjustmentParameter: (PhotosCropAdjustmentParameter) -> Void
  let onSetAdjustmentValue: (Double) -> Void

  var body: some View {
    Group {
      switch mode {
      case .crop:
        PhotosCropAdjustmentControl(
          originalAspectRatio: originalAspectRatio,
          aspectRatioSelection: aspectRatioSelection,
          localizedStrings: localizedStrings,
          adjustmentAngle: adjustmentAngle,
          isSelectingAspectRatio: isSelectingAspectRatio,
          isLoaded: isLoaded,
          onSelectAspectRatio: onSelectAspectRatio,
          onSetAdjustmentAngle: onSetAdjustmentAngle,
          onCommitAdjustmentAngle: onCommitAdjustmentAngle
        )

      case .blurMasking:
        PhotosCropBlurMaskingControl(
          brushDiameter: blurMaskingState.brushDiameter,
          isLoaded: isLoaded,
          onSetBrushDiameter: onSetBrushDiameter,
          onClearBlurMask: onClearBlurMask
        )

      case .filters:
        PhotosCropFilterControl(
          presets: filterPresets,
          selectedPresetIdentifier: currentEffects?.first(of: PresetFeature.self)?.identifier,
          localizedStrings: localizedStrings,
          isLoaded: isLoaded,
          onSelectPreset: onSelectFilterPreset
        )

      case .adjustments:
        PhotosCropAdjustmentsControl(
          selection: adjustmentParameter,
          sliderValue: currentEffects.map { adjustmentParameter.sliderValue(in: $0) } ?? 0,
          isLoaded: isLoaded,
          onSelectParameter: onSelectAdjustmentParameter,
          onSetValue: onSetAdjustmentValue
        )
      }
    }
    .animation(.spring(response: 0.32, dampingFraction: 1), value: mode)
  }
}

private struct PhotosCropToolbar: ToolbarContent {

  let resetTitle: String
  let cancelTitle: String
  let doneTitle: String
  let isLoaded: Bool
  let hasCropChanges: Bool
  let isDoneEnabled: Bool
  let mode: PhotosCropEditingMode
  let isSelectingAspectRatio: Bool
  let onRotate: () -> Void
  let onReset: () -> Void
  let onToggleAspectRatio: () -> Void
  let onSelectMode: (PhotosCropEditingMode) -> Void
  let onCancel: () -> Void
  let onDone: () -> Void

  var body: some ToolbarContent {
    ToolbarItem(placement: .topBarLeading) {
      PhotosCropToolbarTextButton(
        title: cancelTitle,
        accessibilityIdentifier: "photos.crop.cancel",
        isEnabled: true,
        role: .normal,
        minWidth: nil,
        action: onCancel
      )
    }

    if #available(iOS 26.0, *) {
      ToolbarSpacer(.fixed, placement: .topBarLeading)
    }
    
    ToolbarItem(placement: .topBarLeading) {      
      switch mode {
      case .crop:
        PhotosCropToolbarIconButton(
          systemName: "rotate.left",
          accessibilityLabel: "Rotate",
          accessibilityIdentifier: "photos.crop.rotate",
          isEnabled: isLoaded && mode == .crop,
          isHighlighted: false,
          action: onRotate
        )
      case .adjustments:
        EmptyView()
      case .blurMasking:
        EmptyView()
      case .filters:
        EmptyView()
      }
    }
    
    ToolbarItem(placement: .principal) {
      if hasCropChanges && mode == .crop {
        PhotosCropToolbarTextButton(
          title: resetTitle,
          accessibilityIdentifier: "photos.crop.reset",
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
        PhotosCropToolbarIconButton(
          systemName: "aspectratio",
          accessibilityLabel: "Aspect Ratio",
          accessibilityIdentifier: "photos.crop.aspect",
          isEnabled: isLoaded && mode == .crop,
          isHighlighted: isSelectingAspectRatio,
          action: onToggleAspectRatio
        )
      case .adjustments:
        EmptyView()
      case .blurMasking:
        EmptyView()
      case .filters:
        EmptyView()
      }
    }

    if #available(iOS 26.0, *) {
      ToolbarSpacer(.fixed, placement: .topBarTrailing)
    }

    ToolbarItem(placement: .topBarTrailing) {
      PhotosCropToolbarTextButton(
        title: doneTitle,
        accessibilityIdentifier: "photos.crop.done",
        isEnabled: isDoneEnabled,
        role: .highlighted,
        minWidth: nil,
        action: onDone
      )
    }

    ToolbarItem(placement: .bottomBar) {
      PhotosCropModeToolbar(
        selection: mode,
        isLoaded: isLoaded,
        onSelect: onSelectMode
      )
    }
  }
}

private struct PhotosCropToolbarIconButton: View {

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
        .foregroundStyle(isHighlighted ? Color(uiColor: .systemYellow) : Color(white: 0.6))
    }
    .disabled(!isEnabled)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityIdentifier(accessibilityIdentifier)
  }
}

private struct PhotosCropToolbarTextButton: View {

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

private struct PhotosCropModeToolbar: View {

  let selection: PhotosCropEditingMode
  let isLoaded: Bool
  let onSelect: (PhotosCropEditingMode) -> Void

  var body: some View {
    HStack(spacing: 18) {
      ForEach(PhotosCropEditingMode.allCases) { mode in
        PhotosCropModeToolbarButton(
          mode: mode,
          isSelected: selection == mode,
          isEnabled: isLoaded && mode.isAvailable
        ) {
          onSelect(mode)
        }
      }
    }
    .frame(maxWidth: .infinity)
  }
}

private struct PhotosCropModeToolbarButton: View {

  let mode: PhotosCropEditingMode
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
            .frame(width: 32, height: 22)

          Image(systemName: "triangle.fill")
            .font(.system(size: 5, weight: .bold))
            .foregroundStyle(Color(uiColor: .systemYellow))
            .rotationEffect(.degrees(180))
            .offset(y: -7)
            .opacity(isSelected ? 1 : 0)
        }

        Text(mode.title)
          .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
          .lineLimit(1)
          .minimumScaleFactor(0.75)
      }
      .foregroundStyle(foregroundStyle)
      .frame(width: 60, height: 48)
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

private struct PhotosCropBlurMaskingControl: View {

  let brushDiameter: CGFloat
  let isLoaded: Bool
  let onSetBrushDiameter: (CGFloat) -> Void
  let onClearBlurMask: () -> Void

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
        range: PhotosCropBrushSizeMetrics.sizeRange,
        stepCount: PhotosCropBrushSizeMetrics.stepCount,
        style: .photosCropBrushSizeSlider,
        transform: { $0.rounded() },
        hapticIdentity: { value in
          Int(value.rounded()).isMultiple(of: 10) ? AnyHashable(Int(value.rounded())) : nil
        },
        onHaptic: {
          UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.35)
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

      PhotosCropToolbarIconButton(
        systemName: "trash",
        accessibilityLabel: "Clear Blur Mask",
        accessibilityIdentifier: "photos.crop.blur-masking.clear",
        isEnabled: isLoaded,
        isHighlighted: false,
        action: onClearBlurMask
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
          max(Double(brushDiameter), PhotosCropBrushSizeMetrics.sizeRange.lowerBound),
          PhotosCropBrushSizeMetrics.sizeRange.upperBound
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

private enum PhotosCropBrushSizeMetrics {
  static let minimumSize: Double = 8
  static let maximumSize: Double = 64
  static let sizeRange = minimumSize...maximumSize
  static let stepCount = Int(maximumSize - minimumSize)
}

/// A global adjustment parameter editable in PhotosCrop's Adjust mode.
///
/// Each parameter maps a -100...100 (or 0...100 for zero-based ranges) slider
/// value onto the corresponding effect feature. The parameters write into the
/// FeatureTree's global-effects node, which is evaluated before local
/// adjustments and the final crop.
enum PhotosCropAdjustmentParameter: CaseIterable, Identifiable, Equatable {
  case exposure
  case brightness
  case contrast
  case saturation
  case temperature
  case highlights
  case shadows
  case vignette

  var id: Self { self }

  var title: String {
    switch self {
    case .exposure: return "Exposure"
    case .brightness: return "Brightness"
    case .contrast: return "Contrast"
    case .saturation: return "Saturation"
    case .temperature: return "Warmth"
    case .highlights: return "Highlights"
    case .shadows: return "Shadows"
    case .vignette: return "Vignette"
    }
  }

  var systemImageName: String {
    switch self {
    case .exposure: return "plusminus.circle"
    case .brightness: return "sun.max"
    case .contrast: return "circle.lefthalf.filled"
    case .saturation: return "drop"
    case .temperature: return "thermometer.medium"
    case .highlights: return "circle.tophalf.filled"
    case .shadows: return "circle.bottomhalf.filled"
    case .vignette: return "circle.dashed.inset.filled"
    }
  }

  var accessibilityIdentifier: String {
    "photos.crop.adjustments.\(String(describing: self))"
  }

  /// Zero-based parameters only strengthen in one direction.
  private var isZeroBased: Bool {
    switch self {
    case .highlights, .vignette:
      return true
    case .exposure, .brightness, .contrast, .saturation, .temperature, .shadows:
      return false
    }
  }

  var sliderRange: ClosedRange<Double> {
    isZeroBased ? 0...100 : -100...100
  }

  /// The maximum effect value the slider's positive end maps to.
  ///
  /// These mirror the legacy `ParameterRange` maxima; the parametric features
  /// carry unbounded values, so the slider scale is a PhotosCrop policy.
  private var maximumFilterValue: Double {
    switch self {
    case .exposure: return 1.8
    case .brightness: return 0.2
    case .contrast: return 0.18
    case .saturation: return 1
    case .temperature: return 3000
    case .highlights: return 1
    case .shadows: return 1
    case .vignette: return 2
    }
  }

  /// The current slider value for this parameter.
  func sliderValue(in effects: EffectPipeline) -> Double {
    let filterValue: Double
    switch self {
    case .exposure: filterValue = effects.first(of: ExposureFeature.self)?.value ?? 0
    case .brightness: filterValue = effects.first(of: BrightnessFeature.self)?.value ?? 0
    case .contrast: filterValue = effects.first(of: ContrastFeature.self)?.value ?? 0
    case .saturation: filterValue = effects.first(of: SaturationFeature.self)?.value ?? 0
    case .temperature: filterValue = effects.first(of: TemperatureFeature.self)?.value ?? 0
    case .highlights: filterValue = effects.first(of: HighlightsFeature.self)?.value ?? 0
    case .shadows: filterValue = effects.first(of: ShadowsFeature.self)?.value ?? 0
    case .vignette: filterValue = effects.first(of: VignetteFeature.self)?.value ?? 0
    }

    guard maximumFilterValue != 0 else {
      return 0
    }

    return (filterValue / maximumFilterValue * 100).rounded()
  }

  /// Whether this parameter currently deviates from its neutral value.
  func isActive(in effects: EffectPipeline) -> Bool {
    sliderValue(in: effects) != 0
  }

  /// Writes a slider value into the global-effects pipeline. A neutral value
  /// removes the corresponding effect so untouched parameters stay absent
  /// from the edit.
  func apply(sliderValue: Double, to effects: inout EffectPipeline) {
    let clamped = min(max(sliderValue, sliderRange.lowerBound), sliderRange.upperBound)
    let filterValue = clamped / 100 * maximumFilterValue
    let value: Double? = abs(clamped) < 0.5 ? nil : filterValue

    switch self {
    case .exposure:
      upsert(value, into: &effects, make: { ExposureFeature(value: $0) }, update: { $0.value = $1 })
    case .brightness:
      upsert(value, into: &effects, make: { BrightnessFeature(value: $0) }, update: { $0.value = $1 })
    case .contrast:
      upsert(value, into: &effects, make: { ContrastFeature(value: $0) }, update: { $0.value = $1 })
    case .saturation:
      upsert(value, into: &effects, make: { SaturationFeature(value: $0) }, update: { $0.value = $1 })
    case .temperature:
      upsert(value, into: &effects, make: { TemperatureFeature(value: $0) }, update: { $0.value = $1 })
    case .highlights:
      upsert(value, into: &effects, make: { HighlightsFeature(value: $0) }, update: { $0.value = $1 })
    case .shadows:
      upsert(value, into: &effects, make: { ShadowsFeature(value: $0) }, update: { $0.value = $1 })
    case .vignette:
      upsert(value, into: &effects, make: { VignetteFeature(value: $0) }, update: { $0.value = $1 })
    }
  }

  /// Updates an existing effect in place (keeping its feature identity),
  /// inserts a new one at PhotosCrop's canonical position, or removes it when
  /// the slider returns to neutral.
  private func upsert<T: ImageEffectFeatureType>(
    _ value: Double?,
    into effects: inout EffectPipeline,
    make: (Double) -> T,
    update: (inout T, Double) -> Void
  ) {
    guard let value else {
      effects.set(nil as T?)
      return
    }

    if var existing = effects.first(of: T.self) {
      update(&existing, value)
      effects.set(existing)
    } else {
      effects.set(make(value), insertionIndex: PhotosCropEffectOrder.insertionIndex(for: T.self))
    }
  }
}

/// PhotosCrop's canonical evaluation order inside the global-effects node.
///
/// Effect ordering is a UI policy — the engine evaluates whatever sequence the
/// UI assembles — so the table lives here, not in `EditingStack`. Unknown
/// effect types sort after every known one.
enum PhotosCropEffectOrder {

  private static let order: [ObjectIdentifier] = [
    ObjectIdentifier(PresetFeature.self),
    ObjectIdentifier(ExposureFeature.self),
    ObjectIdentifier(BrightnessFeature.self),
    ObjectIdentifier(TemperatureFeature.self),
    ObjectIdentifier(HighlightsFeature.self),
    ObjectIdentifier(ShadowsFeature.self),
    ObjectIdentifier(SaturationFeature.self),
    ObjectIdentifier(ContrastFeature.self),
    ObjectIdentifier(SharpenFeature.self),
    ObjectIdentifier(UnsharpMaskFeature.self),
    ObjectIdentifier(GaussianBlurFeature.self),
    ObjectIdentifier(FadeFeature.self),
    ObjectIdentifier(VignetteFeature.self),
  ]

  private static func rank(of typeIdentity: ObjectIdentifier) -> Int {
    order.firstIndex(of: typeIdentity) ?? order.count
  }

  /// The index where a new effect of `type` keeps the canonical order.
  static func insertionIndex<T: ImageEffectFeatureType>(
    for type: T.Type
  ) -> (EffectPipeline) -> Int {
    let newRank = rank(of: ObjectIdentifier(type))
    return { pipeline in
      pipeline.effects.firstIndex { existing in
        rank(of: ObjectIdentifier(Swift.type(of: existing))) > newRank
      } ?? pipeline.effects.count
    }
  }
}

/// Filter preset chips evaluated inside the global-effects feature node.
private struct PhotosCropFilterControl: View {

  let presets: [PresetFeature]
  let selectedPresetIdentifier: String?
  let localizedStrings: SwiftUIPhotosCropView.LocalizedStrings
  let isLoaded: Bool
  let onSelectPreset: (PresetFeature?) -> Void

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 12) {
        PhotosCropAspectRatioButton(
          title: localizedStrings.button_filter_original,
          isSelected: selectedPresetIdentifier == nil
        ) {
          onSelectPreset(nil)
        }
        .accessibilityIdentifier("photos.crop.filters.original")

        ForEach(presets, id: \.identifier) { preset in
          PhotosCropAspectRatioButton(
            title: preset.name,
            isSelected: selectedPresetIdentifier == preset.identifier
          ) {
            onSelectPreset(preset)
          }
          .accessibilityIdentifier("photos.crop.filters.\(preset.identifier)")
        }
      }
      .padding(.horizontal, 24)
      .frame(maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .opacity(isLoaded ? 1 : 0.5)
    .disabled(!isLoaded)
    .environment(\.colorScheme, .dark)
    .accessibilityIdentifier("photos.crop.filters")
  }
}

/// Parameter selector plus value slider for PhotosCrop's Adjust mode.
private struct PhotosCropAdjustmentsControl: View {

  let selection: PhotosCropAdjustmentParameter
  let sliderValue: Double
  let isLoaded: Bool
  let onSelectParameter: (PhotosCropAdjustmentParameter) -> Void
  let onSetValue: (Double) -> Void

  var body: some View {
    VStack(spacing: 4) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 16) {
          ForEach(PhotosCropAdjustmentParameter.allCases) { parameter in
            PhotosCropAdjustmentParameterButton(
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
        stepCount: Int((selection.sliderRange.upperBound - selection.sliderRange.lowerBound) / 4),
        style: .photosCropAdjustmentSlider,
        resetValue: 0,
        snapsToTicksOnEditingEnd: false,
        transform: { $0.rounded() },
        hapticIdentity: { value in
          let step = Int(value.rounded())
          return step.isMultiple(of: 25) ? AnyHashable(step) : nil
        },
        onHaptic: {
          UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.35)
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
      .padding(.horizontal, 24)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .opacity(isLoaded ? 1 : 0.5)
    .disabled(!isLoaded)
    .environment(\.colorScheme, .dark)
    .accessibilityIdentifier("photos.crop.adjustments")
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

private struct PhotosCropAdjustmentParameterButton: View {

  let parameter: PhotosCropAdjustmentParameter
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

private struct PhotosCropAdjustmentControl: View {

  let originalAspectRatio: PixelAspectRatio?
  let aspectRatioSelection: PhotosCropAspectRatioSelection
  let localizedStrings: SwiftUIPhotosCropView.LocalizedStrings
  let adjustmentAngle: CropEditingState.AdjustmentAngle?
  let isSelectingAspectRatio: Bool
  let isLoaded: Bool
  let onSelectAspectRatio: (PhotosCropAspectRatioSelection) -> Void
  let onSetAdjustmentAngle: (Double) -> Void
  let onCommitAdjustmentAngle: (Double) -> Void

  var body: some View {
    Group {
      if isSelectingAspectRatio, let originalAspectRatio {
        PhotosCropAspectRatioPicker(
          originalAspectRatio: originalAspectRatio,
          selection: aspectRatioSelection,
          localizedStrings: localizedStrings,
          onSelect: onSelectAspectRatio
        )
        .transition(.opacity)
      } else {
        PhotosCropRotationSlider(
          value: adjustmentAngle?.degrees ?? 0,
          isEnabled: isLoaded,
          onChange: onSetAdjustmentAngle,
          onEditingEnded: onCommitAdjustmentAngle
        )
        .transition(.opacity)
      }
    }
    .animation(.spring(response: 0.35, dampingFraction: 1), value: isSelectingAspectRatio)
  }
}

private struct PhotosCropRotationSlider: View {

  let value: Double
  let isEnabled: Bool
  let onChange: (Double) -> Void
  let onEditingEnded: (Double) -> Void

  var body: some View {
    BrightroomSteppedSlider(
      value: valueBinding,
      range: -45...45,
      stepCount: 90,
      style: .photosCropRotationSlider,
      resetValue: 0,
      snapsToTicksOnEditingEnd: false,
      transform: { source in
        if (-PhotosCropRotationSliderMetrics.neutralDeadZoneDegrees...PhotosCropRotationSliderMetrics.neutralDeadZoneDegrees).contains(source) {
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

private enum PhotosCropRotationSliderMetrics {
  static let neutralDeadZoneDegrees: Double = 0.5
}

private extension BrightroomSteppedSliderStyle {
  static let photosCropRotationSlider = BrightroomSteppedSliderStyle(
    tickWidth: 2,
    tickSpacing: 4,
    tickHeight: 10,
    activeTickWidth: 3,
    activeTickHeight: 18,
    majorTickInterval: 5
  )

  static let photosCropAdjustmentSlider = BrightroomSteppedSliderStyle(
    tickWidth: 2,
    tickSpacing: 4,
    tickHeight: 10,
    activeTickWidth: 3,
    activeTickHeight: 18,
    majorTickInterval: 5
  )

  static let photosCropBrushSizeSlider = BrightroomSteppedSliderStyle(
    tickWidth: 2,
    tickSpacing: 4,
    tickHeight: 10,
    activeTickWidth: 3,
    activeTickHeight: 18,
    majorTickInterval: 8
  )
}

private extension BrightroomSteppedSliderTickContext {
  var isZero: Bool {
    abs(value) < 0.000_001
  }
}

private enum PhotosCropAspectRatioSelection: Equatable {

  case freeform
  case original(PhotosCropAspectRatioDirection)
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

  func aspectRatio(originalAspectRatio: PixelAspectRatio?) -> PixelAspectRatio? {
    switch self {
    case .freeform:
      return nil
    case .original(let direction):
      return originalAspectRatio.map { direction.orient($0) }
    case .ratio(let aspectRatio):
      return aspectRatio
    }
  }

  func direction(originalAspectRatio: PixelAspectRatio?) -> PhotosCropAspectRatioDirection? {
    switch self {
    case .freeform:
      return nil
    case .original(let direction):
      return direction
    case .ratio(let aspectRatio):
      return PhotosCropAspectRatioDirection(aspectRatio)
    }
  }

  func withDirection(
    _ direction: PhotosCropAspectRatioDirection,
    originalAspectRatio: PixelAspectRatio?
  ) -> Self {
    switch self {
    case .freeform:
      return .freeform
    case .original:
      return .original(direction)
    case .ratio(let aspectRatio):
      if PhotosCropAspectRatioDirection(aspectRatio) == direction {
        return self
      } else {
        return .ratio(aspectRatio.swapped())
      }
    }
  }

  mutating func sync(aspectRatio: PixelAspectRatio?, originalAspectRatio: PixelAspectRatio?) {
    guard self.aspectRatio(originalAspectRatio: originalAspectRatio) != aspectRatio else {
      return
    }

    if case .original = self, let aspectRatio, let originalAspectRatio {
      if aspectRatio == originalAspectRatio {
        self = .original(PhotosCropAspectRatioDirection(originalAspectRatio))
        return
      }

      let swappedOriginalAspectRatio = originalAspectRatio.swapped()
      if aspectRatio == swappedOriginalAspectRatio {
        self = .original(PhotosCropAspectRatioDirection(swappedOriginalAspectRatio))
        return
      }
    }

    self = .init(aspectRatio: aspectRatio)
  }
}

private struct PhotosCropAspectRatioPicker: View {

  let originalAspectRatio: PixelAspectRatio?
  let selection: PhotosCropAspectRatioSelection
  let localizedStrings: SwiftUIPhotosCropView.LocalizedStrings
  let onSelect: (PhotosCropAspectRatioSelection) -> Void

  var body: some View {
    VStack(spacing: 24) {
      HStack(spacing: 18) {
        PhotosCropAspectRatioDirectionButton(
          direction: .vertical,
          selectedDirection: selectedDirection,
          isEnabled: canSelectDirection,
          onSelect: selectDirection
        )

        PhotosCropAspectRatioDirectionButton(
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
            PhotosCropAspectRatioButton(
              title: localizedStrings.button_aspectratio_original,
              isSelected: selection.isOriginal
            ) {
              onSelect(.original(selectedDirection))
            }
            .accessibilityIdentifier("photos.crop.aspect.original")
          }

          PhotosCropAspectRatioButton(
            title: localizedStrings.button_aspectratio_freeform,
            isSelected: selection.isFreeform
          ) {
            onSelect(.freeform)
          }
          .accessibilityIdentifier("photos.crop.aspect.freeform")

          PhotosCropAspectRatioButton(
            title: localizedStrings.button_aspectratio_square,
            isSelected: selection.isRatio(.square)
          ) {
            onSelect(.ratio(.square))
          }
          .accessibilityIdentifier("photos.crop.aspect.square")

          ForEach(Self.horizontalRectangleAspectRatios) { ratio in
            let displayedRatio = displayedRatio(for: ratio)
            let minimizedDisplayedRatio = displayedRatio._minimized()

            PhotosCropAspectRatioButton(
              title: "\(Int(minimizedDisplayedRatio.width)):\(Int(minimizedDisplayedRatio.height))",
              isSelected: selection.isRatio(minimizedDisplayedRatio)
            ) {
              onSelect(.ratio(minimizedDisplayedRatio))
            }
            .accessibilityIdentifier("photos.crop.aspect.\(Int(minimizedDisplayedRatio.width))x\(Int(minimizedDisplayedRatio.height))")
          }
        }
        .padding(.horizontal, 24)
      }
    }
  }

  private var selectedDirection: PhotosCropAspectRatioDirection {
    selection.direction(originalAspectRatio: originalAspectRatio) ?? originalDirection
  }

  private var originalDirection: PhotosCropAspectRatioDirection {
    originalAspectRatio.map(PhotosCropAspectRatioDirection.init) ?? .horizontal
  }

  private var canSelectDirection: Bool {
    guard let selectedAspectRatio = selection.aspectRatio(originalAspectRatio: originalAspectRatio), selectedAspectRatio != .square else {
      return false
    }

    return true
  }

  private func displayedRatio(for horizontalRatio: PixelAspectRatio) -> PixelAspectRatio {
    switch selectedDirection {
    case .horizontal:
      return horizontalRatio
    case .vertical:
      return horizontalRatio.swapped()
    }
  }

  private func selectDirection(_ direction: PhotosCropAspectRatioDirection) {
    guard canSelectDirection, selectedDirection != direction else {
      return
    }

    onSelect(selection.withDirection(direction, originalAspectRatio: originalAspectRatio))
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

private struct PhotosCropAspectRatioButton: View {

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

private struct PhotosCropAspectRatioDirectionButton: View {

  let direction: PhotosCropAspectRatioDirection
  let selectedDirection: PhotosCropAspectRatioDirection
  let isEnabled: Bool
  let onSelect: (PhotosCropAspectRatioDirection) -> Void

  var body: some View {
    Button {
      onSelect(direction)
    } label: {
      ZStack {
        RoundedRectangle(cornerRadius: 4)
          .fill(isSelected && isEnabled ? Color(white: 0.6) : Color.black.opacity(0.6))

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

private enum PhotosCropAspectRatioDirection {
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
    if PhotosCropAspectRatioDirection(aspectRatio) == self {
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
      return "photos.crop.aspect.direction.vertical"
    case .horizontal:
      return "photos.crop.aspect.direction.horizontal"
    }
  }
}

#if DEBUG

#Preview("PhotosCrop Checkerboard") {
  PhotosCropPreviewHost()
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

private struct PhotosCropPreviewHost: View {

  @State private var editingStack = PhotosCropPreviewFixtures.makeEditingStack()

  var body: some View {
    SwiftUIPhotosCropView(
      editingStack: editingStack,
      onDone: {},
      onCancel: {}
    )
  }
}

private enum PhotosCropPreviewFixtures {

  static func makeEditingStack() -> EditingStack {
    EditingStack(
      imageProvider: .init(image: makeCheckerboardImage())
    )
  }

  private static func makeCheckerboardImage() -> UIImage {
    let size = CGSize(width: 1400, height: 900)
    let cellSize: CGFloat = 100
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1

    return UIGraphicsImageRenderer(size: size, format: format).image { context in
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
          let color = (row + column).isMultiple(of: 2)
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
