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

import PrecisionLevelSlider
import SwiftUI
import UIKit

import BrightroomEngine

struct PhotosCropContentView: View {

  let editingStack: EditingStack
  let options: SwiftUIPhotosCropView.Options
  let localizedStrings: SwiftUIPhotosCropView.LocalizedStrings
  let onDone: @MainActor () -> Void
  let onCancel: @MainActor () -> Void

  @State private var rotation: EditingCrop.Rotation?
  @State private var adjustmentAngle: EditingCrop.AdjustmentAngle?
  @State private var aspectRatioSelection: PhotosCropAspectRatioSelection
  @State private var isSelectingAspectRatio = false
  @State private var resetAction = SwiftUICropView.ResetAction()
  @State private var rotateAction = SwiftUICropView.RotateAction()
  @State private var applyAction = SwiftUICropView.ApplyAction()

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
    let topBarHeight: CGFloat = 44
    let bottomControlHeight: CGFloat = 112
    let bottomBarHeight: CGFloat = 50

    ZStack {
      Color.black
        .ignoresSafeArea()

      VStack(spacing: 0) {
        Spacer(minLength: topBarHeight)
          .fixedSize()

        SwiftUICropView(
          editingStack: editingStack,
          isAutoApplyEditingStackEnabled: true
        )
        .rotation($rotation)
        .adjustmentAngle($adjustmentAngle)
        .croppingAspectRatio(croppingAspectRatioBinding(originalAspectRatio: originalAspectRatio))
        .registerResetAction(resetAction)
        .registerRotateAction(rotateAction)
        .registerApplyAction(applyAction)
        .layoutPriority(1)

        Spacer(minLength: bottomControlHeight + bottomBarHeight)
          .fixedSize()
      }

      VStack(spacing: 0) {
        PhotosCropTopBar(
          resetTitle: localizedStrings.button_reset_title,
          isEnabled: isLoaded,
          hasChanges: loadedState?.isDirty ?? false,
          isAspectRatioControlAvailable: isAspectRatioControlAvailable,
          isSelectingAspectRatio: isSelectingAspectRatio,
          onRotate: rotate,
          onReset: reset,
          onToggleAspectRatio: toggleAspectRatioControl
        )
        .frame(height: topBarHeight)
        .padding(.horizontal, 16)

        Spacer(minLength: 0)

        Group {
          if isSelectingAspectRatio && originalAspectRatio != nil {
            PhotosCropAspectRatioPicker(
              originalAspectRatio: originalAspectRatio,
              selection: aspectRatioSelection,
              localizedStrings: localizedStrings,
              onSelect: selectAspectRatio
            )
            .transition(.opacity)
          } else {
            PhotosCropRotationSlider(
              value: adjustmentAngle?.degrees ?? 0,
              isEnabled: isLoaded,
              onChange: setAdjustmentAngle
            )
            .transition(.opacity)
          }
        }
        .frame(height: bottomControlHeight)
        .animation(.spring(response: 0.35, dampingFraction: 1), value: isSelectingAspectRatio)

        PhotosCropBottomBar(
          cancelTitle: localizedStrings.button_cancel_title,
          doneTitle: localizedStrings.button_done_title,
          isDoneEnabled: isLoaded,
          onCancel: onCancel,
          onDone: finish
        )
        .frame(height: bottomBarHeight)
        .padding(.horizontal, 16)
      }
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
    .accessibilityIdentifier("photos.crop")
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
    guard isAspectRatioControlAvailable else {
      return
    }

    isSelectingAspectRatio.toggle()
  }

  private func selectAspectRatio(_ selection: PhotosCropAspectRatioSelection) {
    aspectRatioSelection = selection
  }

  private func setAdjustmentAngle(_ degrees: Double) {
    let angle = EditingCrop.AdjustmentAngle(degrees: degrees)

    guard adjustmentAngle != angle else {
      return
    }

    adjustmentAngle = angle
  }

  private func finish() {
    applyAction()
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

private struct PhotosCropTopBar: View {

  let resetTitle: String
  let isEnabled: Bool
  let hasChanges: Bool
  let isAspectRatioControlAvailable: Bool
  let isSelectingAspectRatio: Bool
  let onRotate: () -> Void
  let onReset: () -> Void
  let onToggleAspectRatio: () -> Void

  var body: some View {
    HStack {
      Button(action: onRotate) {
        Image(systemName: "rotate.left")
          .font(.system(size: 22, weight: .regular))
          .symbolRenderingMode(.monochrome)
          .foregroundStyle(Color(white: 0.6))
          .frame(width: 44, height: 44)
      }
      .buttonStyle(.plain)
      .disabled(!isEnabled)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Rotate")
      .accessibilityIdentifier("photos.crop.rotate")

      Spacer()

      Group {
        if hasChanges {
          Button(action: onReset) {
            Text(resetTitle)
              .font(.system(size: 14))
              .foregroundStyle(Color(uiColor: .systemYellow))
          }
          .buttonStyle(.plain)
          .disabled(!isEnabled)
          .accessibilityIdentifier("photos.crop.reset")
        } else {
          Color.clear
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)
        }
      }

      Spacer()

      Button(action: onToggleAspectRatio) {
        Image(systemName: "aspectratio")
          .font(.system(size: 22, weight: .regular))
          .symbolRenderingMode(.monochrome)
          .foregroundStyle(isSelectingAspectRatio ? Color(uiColor: .systemYellow) : Color(white: 0.6))
          .frame(width: 44, height: 44)
      }
      .buttonStyle(.plain)
      .opacity(isAspectRatioControlAvailable ? 1 : 0)
      .disabled(!isEnabled || !isAspectRatioControlAvailable)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Aspect Ratio")
      .accessibilityIdentifier("photos.crop.aspect")
    }
  }
}

private struct PhotosCropBottomBar: View {

  let cancelTitle: String
  let doneTitle: String
  let isDoneEnabled: Bool
  let onCancel: () -> Void
  let onDone: () -> Void

  var body: some View {
    HStack {
      Button(action: onCancel) {
        Text(cancelTitle)
          .font(.system(size: 17))
          .foregroundStyle(.white)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("photos.crop.cancel")

      Spacer()

      Button(action: onDone) {
        Text(doneTitle)
          .font(.system(size: 17))
          .foregroundStyle(isDoneEnabled ? Color(uiColor: .systemYellow) : Color(uiColor: .darkGray))
      }
      .buttonStyle(.plain)
      .disabled(!isDoneEnabled)
      .accessibilityIdentifier("photos.crop.done")
    }
  }
}

private struct PhotosCropRotationSlider: View {

  let value: Double
  let isEnabled: Bool
  let onChange: (Double) -> Void

  var body: some View {
    PhotosCropPrecisionLevelSlider(
      value: valueBinding,
      haptics: .init(trigger: { value in
        if value.truncatingRemainder(dividingBy: 5) == 0 {
          return .impact(style: .light, intensity: 0.4)
        } else {
          return nil
        }
      }),
      range: .init(
        range: -45...45,
        transform: { source in
          source.rounded(.toNearestOrEven)
        }
      ),
      centerLevel: { _, _ in
        HStack {
          Spacer()
          VStack {
            Spacer(minLength: 12)
            Rectangle()
              .frame(width: 1)
            Spacer(minLength: 12)
          }
          Spacer()
        }
        .foregroundStyle(.tint)
      },
      track: { value, _ in
        PhotosCropRotationTickTrack(value: value)
      }
    )
    .tint(.white)
    .accentColor(.white)
    .frame(height: 50)
    .padding(.horizontal, 24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .opacity(isEnabled ? 1 : 0.5)
    .disabled(!isEnabled)
    .accessibilityLabel("Rotation")
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

private struct PhotosCropPrecisionLevelSlider<CenterLevel: View, Track: View>: UIViewRepresentable {

  @Binding var value: Double

  let haptics: PrecisionLevelSlider.Haptics?
  let range: PrecisionLevelSlider.ValueRange
  let centerLevel: (Double, Bool) -> CenterLevel
  let track: (Double, Bool) -> Track

  init(
    value: Binding<Double>,
    haptics: PrecisionLevelSlider.Haptics?,
    range: PrecisionLevelSlider.ValueRange,
    @ViewBuilder centerLevel: @escaping (Double, Bool) -> CenterLevel,
    @ViewBuilder track: @escaping (Double, Bool) -> Track
  ) {
    self._value = value
    self.haptics = haptics
    self.range = range
    self.centerLevel = centerLevel
    self.track = track
  }

  func makeUIView(context: Context) -> PrecisionLevelSlider {
    let view = PrecisionLevelSlider(
      range: range,
      haptics: haptics,
      centerLevel: centerLevel,
      track: track
    )

    view.onChangeValue = { value in
      Task { @MainActor in
        self.value = value
      }
    }

    return view
  }

  func updateUIView(_ uiView: PrecisionLevelSlider, context: Context) {
    uiView.range = range

    guard uiView.value != value else {
      return
    }

    uiView.value = value
  }
}

private struct PhotosCropRotationTickTrack: View {

  let value: Double

  var body: some View {
    VStack {
      HStack {
        Spacer()
        Circle()
          .frame(width: 6, height: 6)
          .opacity(value == 0 ? 0 : 1)
          .animation(.spring, value: value == 0)
        Spacer()
      }

      HStack(spacing: 0) {
        ForEach(0..<4) { _ in
          PhotosCropRotationShortBar()
            .foregroundStyle(.primary)
          Group {
            Spacer(minLength: 0)
            PhotosCropRotationShortBar()
            Spacer(minLength: 0)
            PhotosCropRotationShortBar()
            Spacer(minLength: 0)
            PhotosCropRotationShortBar()
            Spacer(minLength: 0)
            PhotosCropRotationShortBar()
            Spacer(minLength: 0)
            PhotosCropRotationShortBar()
            Spacer(minLength: 0)
            PhotosCropRotationShortBar()
            Spacer(minLength: 0)
            PhotosCropRotationShortBar()
            Spacer(minLength: 0)
            PhotosCropRotationShortBar()
            Spacer(minLength: 0)
            PhotosCropRotationShortBar()
            Spacer(minLength: 0)
          }
          .foregroundStyle(.secondary)
        }
        PhotosCropRotationShortBar()
          .foregroundStyle(.primary)
      }
    }
    .foregroundStyle(.tint)
  }
}

private struct PhotosCropRotationShortBar: View {
  var body: some View {
    RoundedRectangle(cornerRadius: 8)
      .frame(width: 1, height: 10)
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
