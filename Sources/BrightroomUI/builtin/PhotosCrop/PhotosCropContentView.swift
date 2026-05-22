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

struct PhotosCropContentView: View {

  let editingStack: EditingStack
  let options: SwiftUIPhotosCropView.Options
  let localizedStrings: SwiftUIPhotosCropView.LocalizedStrings
  let onDone: @MainActor () -> Void
  let onCancel: @MainActor () -> Void

  @State private var cropState: CropView.StateSnapshot?
  @State private var rotation: EditingCrop.Rotation?
  @State private var croppingAspectRatio: PixelAspectRatio?
  @State private var isSelectingAspectRatio = false
  @State private var resetAction = SwiftUICropView.ResetAction()
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
      self._croppingAspectRatio = State(initialValue: aspectRatio)
    case .selectable:
      self._croppingAspectRatio = State(initialValue: nil)
    }
  }

  var body: some View {
    let loadedState = editingStack.loadedState
    let originalAspectRatio = loadedState.map { PixelAspectRatio($0.imageSize) }
    let isLoaded = loadedState != nil
    let topBarHeight: CGFloat = 44
    let aspectRatioPickerHeight: CGFloat = 112
    let bottomBarHeight: CGFloat = 50

    ZStack {
      VStack(spacing: 0) {
        Color.clear
          .frame(height: topBarHeight)

        SwiftUICropView(
          editingStack: editingStack,
          isAutoApplyEditingStackEnabled: true,
          stateHandler: handleCropState
        )
        .rotation(rotation)
        .croppingAspectRatio(croppingAspectRatio)
        .registerResetAction(resetAction)
        .registerApplyAction(applyAction)
        .layoutPriority(1)

        Color.clear
          .frame(height: aspectRatioPickerHeight + bottomBarHeight)
      }

      VStack(spacing: 0) {
        PhotosCropTopBar(
          resetTitle: localizedStrings.button_reset_title,
          isEnabled: isLoaded,
          hasUncommitedChanges: loadedState?.hasUncommitedChanges ?? false,
          isAspectRatioControlAvailable: isAspectRatioControlAvailable,
          isSelectingAspectRatio: isSelectingAspectRatio,
          onRotate: rotate,
          onReset: reset,
          onToggleAspectRatio: toggleAspectRatioControl
        )
        .frame(height: topBarHeight)
        .padding(.horizontal, 16)

        Spacer(minLength: 0)

        PhotosCropAspectRatioPicker(
          originalAspectRatio: originalAspectRatio,
          selectedAspectRatio: croppingAspectRatio,
          localizedStrings: localizedStrings,
          onSelect: selectAspectRatio
        )
        .frame(height: aspectRatioPickerHeight)
        .opacity(isSelectingAspectRatio && originalAspectRatio != nil ? 1 : 0)
        .allowsHitTesting(isSelectingAspectRatio && originalAspectRatio != nil)
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
    .background {
      Color.black
        .ignoresSafeArea()
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

  @MainActor
  private func handleCropState(_ state: CropView.StateSnapshot) {
    cropState = state

    if let proposedCrop = state.proposedCrop, rotation != proposedCrop.rotation {
      rotation = proposedCrop.rotation
    }

    if croppingAspectRatio != state.preferredAspectRatio {
      croppingAspectRatio = state.preferredAspectRatio
    }
  }

  private func rotate() {
    guard let proposedCrop = cropState?.proposedCrop else {
      return
    }

    rotation = proposedCrop.rotation.next()

    if let aspectRatio = cropState?.preferredAspectRatio {
      croppingAspectRatio = aspectRatio.swapped()
    }
  }

  private func reset() {
    switch options.aspectRatioOptions {
    case .fixed(let aspectRatio):
      croppingAspectRatio = aspectRatio
    case .selectable:
      croppingAspectRatio = nil
    }

    resetAction()
  }

  private func toggleAspectRatioControl() {
    guard isAspectRatioControlAvailable else {
      return
    }

    isSelectingAspectRatio.toggle()
  }

  private func selectAspectRatio(_ aspectRatio: PixelAspectRatio?) {
    croppingAspectRatio = aspectRatio
  }

  private func finish() {
    applyAction()
    onDone()
  }
}

private struct PhotosCropTopBar: View {

  let resetTitle: String
  let isEnabled: Bool
  let hasUncommitedChanges: Bool
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

      Button(action: onReset) {
        Text(resetTitle)
          .font(.system(size: 14))
          .foregroundStyle(Color(uiColor: .systemYellow))
      }
      .buttonStyle(.plain)
      .opacity(hasUncommitedChanges ? 1 : 0)
      .disabled(!isEnabled || !hasUncommitedChanges)
      .accessibilityIdentifier("photos.crop.reset")

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

private struct PhotosCropAspectRatioPicker: View {

  let originalAspectRatio: PixelAspectRatio?
  let selectedAspectRatio: PixelAspectRatio?
  let localizedStrings: SwiftUIPhotosCropView.LocalizedStrings
  let onSelect: (PixelAspectRatio?) -> Void

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
              isSelected: selectedAspectRatio == originalAspectRatioForCurrentDirection
            ) {
              onSelect(originalAspectRatioForCurrentDirection)
            }
            .accessibilityIdentifier("photos.crop.aspect.original")
          }

          PhotosCropAspectRatioButton(
            title: localizedStrings.button_aspectratio_freeform,
            isSelected: selectedAspectRatio == nil
          ) {
            onSelect(nil)
          }
          .accessibilityIdentifier("photos.crop.aspect.freeform")

          PhotosCropAspectRatioButton(
            title: localizedStrings.button_aspectratio_square,
            isSelected: selectedAspectRatio == .square
          ) {
            onSelect(.square)
          }
          .accessibilityIdentifier("photos.crop.aspect.square")

          ForEach(Self.horizontalRectangleAspectRatios) { ratio in
            let displayedRatio = displayedRatio(for: ratio)

            PhotosCropAspectRatioButton(
              title: "\(Int(displayedRatio.width)):\(Int(displayedRatio.height))",
              isSelected: selectedAspectRatio == displayedRatio
            ) {
              onSelect(displayedRatio)
            }
            .accessibilityIdentifier("photos.crop.aspect.\(Int(displayedRatio.width))x\(Int(displayedRatio.height))")
          }
        }
        .padding(.horizontal, 24)
      }
    }
  }

  private var selectedDirection: PhotosCropAspectRatioDirection {
    selectedAspectRatio.map(PhotosCropAspectRatioDirection.init) ?? originalDirection
  }

  private var originalDirection: PhotosCropAspectRatioDirection {
    originalAspectRatio.map(PhotosCropAspectRatioDirection.init) ?? .horizontal
  }

  private var canSelectDirection: Bool {
    guard let selectedAspectRatio else {
      return false
    }

    guard selectedAspectRatio != .square else {
      return false
    }

    return true
  }

  private var originalAspectRatioForCurrentDirection: PixelAspectRatio? {
    guard let originalAspectRatio else {
      return nil
    }

    if PhotosCropAspectRatioDirection(originalAspectRatio) == selectedDirection {
      return originalAspectRatio
    } else {
      return originalAspectRatio.swapped()
    }
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
    guard let selectedAspectRatio else {
      return
    }

    guard PhotosCropAspectRatioDirection(selectedAspectRatio) != direction else {
      return
    }

    onSelect(selectedAspectRatio.swapped())
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
          .fill(isSelected ? Color(white: 0.6) : Color.black.opacity(0.6))

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
}
