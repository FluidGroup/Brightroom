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

import CoreImage
import PrecisionLevelSlider
import SwiftUI
import UIKit

import BrightroomEngine

public struct SwiftUIPixelEditorView: View {

  @State private var viewModel: ClassicImageEditViewModel
  @State private var controlRoute: PixelEditorControlRoute = .root
  @State private var displayedRootPanel: PixelEditorRootPanel = .filter

  private let onEndEditing: (EditingStack) -> Void
  private let onCancelEditing: () -> Void

  public init(
    editingStack: EditingStack,
    options: ClassicImageEditOptions = .default,
    localizedStrings: ClassicImageEditViewController.LocalizedStrings = .init(),
    onEndEditing: @escaping (EditingStack) -> Void = { _ in },
    onCancelEditing: @escaping () -> Void = {}
  ) {
    self._viewModel = State(
      initialValue: ClassicImageEditViewModel(
        editingStack: editingStack,
        options: options,
        localizedStrings: localizedStrings
      )
    )
    self.onEndEditing = onEndEditing
    self.onCancelEditing = onCancelEditing
  }

  public var body: some View {
    GeometryReader { proxy in
      VStack(spacing: 0) {
        PixelEditorTopBar(
          mode: viewModel.mode,
          title: viewModel.title,
          cancelText: viewModel.localizedStrings.cancel,
          doneText: viewModel.localizedStrings.done,
          onCancel: onCancelEditing,
          onDone: {
            onEndEditing(viewModel.editingStack)
          }
        )

        PixelEditorCanvas(viewModel: viewModel)
          .frame(width: proxy.size.width, height: proxy.size.width)

        PixelEditorControlPanel(
          viewModel: viewModel,
          route: $controlRoute,
          displayedRootPanel: $displayedRootPanel
        )
      }
      .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(PixelEditorColor.background)
    .task {
      viewModel.editingStack.start()
    }
    .accessibilityIdentifier("swiftui.pixel.editor")
  }
}

private enum PixelEditorControlRoute: Equatable {
  case root
  case crop
  case masking
  case filter(PixelEditorFilterKind)
}

private enum PixelEditorRootPanel {
  case filter
  case edit
}

private enum PixelEditorFilterKind: CaseIterable {
  case exposure
  case gaussianBlur
  case contrast
  case temperature
  case saturation
  case highlights
  case shadows
  case vignette
  case fade
  case sharpen
  case clarity
}

private enum PixelEditorLayout {
  static let topBarContentHeight: CGFloat = 56
  static let topBarHeight: CGFloat = 72
  static let previewButtonHeight: CGFloat = 32
  static let horizontalMargin: CGFloat = 20
  static let controlHorizontalMargin: CGFloat = 44
}

private enum PixelEditorColor {
  static let background = Color(uiColor: .systemBackground)
  static let primary = Color(uiColor: .label)
  static let secondary = Color(uiColor: .secondaryLabel)
  static let controlFill = Color(uiColor: .tertiarySystemFill)
  static let accent = Color(uiColor: .systemBlue)
  static let cropGuide = Color.white
}

private struct PixelEditorTopBar: View {

  let mode: ClassicImageEditViewModel.Mode
  let title: String
  let cancelText: String
  let doneText: String
  let onCancel: () -> Void
  let onDone: () -> Void

  var body: some View {
    ZStack {
      switch mode {
      case .preview:
        HStack {
          PixelEditorPreviewButton(
            title: cancelText,
            style: .cancel,
            action: onCancel
          )
            .accessibilityIdentifier("swiftui.pixel.cancel")

          Spacer()

          PixelEditorPreviewButton(
            title: doneText,
            style: .done,
            action: onDone
          )
            .accessibilityIdentifier("swiftui.pixel.done")
        }

      case .crop, .masking, .editing:
        Text(title)
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(PixelEditorColor.primary)
      }
    }
    .padding(.horizontal, PixelEditorLayout.horizontalMargin)
    .frame(height: PixelEditorLayout.topBarContentHeight)
    .frame(height: PixelEditorLayout.topBarHeight, alignment: .top)
  }
}

private struct PixelEditorPreviewButton: View {

  enum Style {
    case cancel
    case done
  }

  let title: String
  let style: Style
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 15, weight: fontWeight))
        .foregroundStyle(foregroundColor)
        .padding(.horizontal, 13)
        .frame(height: PixelEditorLayout.previewButtonHeight)
        .background {
          Capsule()
            .fill(backgroundColor)
        }
    }
    .buttonStyle(.plain)
  }

  private var foregroundColor: Color {
    switch style {
    case .cancel:
      return PixelEditorColor.primary
    case .done:
      return .white
    }
  }

  private var fontWeight: Font.Weight {
    switch style {
    case .cancel:
      return .regular
    case .done:
      return .semibold
    }
  }

  private var backgroundColor: Color {
    switch style {
    case .cancel:
      return PixelEditorColor.controlFill
    case .done:
      return PixelEditorColor.accent
    }
  }
}

private struct PixelEditorCanvas: View {

  let viewModel: ClassicImageEditViewModel

  var body: some View {
    ZStack {
      PixelEditorImagePreviewRepresentable(
        editingStack: viewModel.editingStack,
        displayBackground: .color(.systemBackground)
      )
        .opacity(viewModel.mode.isCrop ? 0 : 1)
        .allowsHitTesting(false)

      SwiftUIBlurryMaskingView(editingStack: viewModel.editingStack)
        .blushSize(viewModel.maskingBrushSize)
        .hideBackdropImageView(true)
        .hideBlurryImageView(viewModel.mode.isEditing || viewModel.mode.isCrop)
        .opacity(viewModel.mode.displaysMaskingView ? 1 : 0)
        .allowsHitTesting(viewModel.mode.isMasking)

      SwiftUICropView(
        editingStack: viewModel.editingStack,
        isGuideInteractionEnabled: viewModel.options.croppingAspectRatio == nil,
        isAutoApplyEditingStackEnabled: false,
        contentInset: .zero,
        cropInsideOverlay: { adjustmentKind in
          if viewModel.options.croppingAspectRatio == nil {
            PixelEditorFreeCropGuideOverlay(isAdjustmentActive: adjustmentKind != nil)
          }
        },
        cropOutsideOverlay: { _ in
          PixelEditorColor.background
        },
        stateHandler: { state in
          if let proposedCrop = state.proposedCrop {
            viewModel.setProposedCrop(proposedCrop)
          }
        }
      )
      .croppingAspectRatio(viewModel.options.croppingAspectRatio)
      .opacity(viewModel.mode.isCrop ? 1 : 0)
      .allowsHitTesting(viewModel.mode.isCrop)

      if viewModel.editingStack.isLoading {
        ProgressView()
          .progressViewStyle(.circular)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(PixelEditorColor.background.opacity(0.5))
      }
    }
    .clipped()
  }
}

private struct PixelEditorFreeCropGuideOverlay: View {

  let isAdjustmentActive: Bool

  var body: some View {
    ZStack {
      Rectangle()
        .stroke(PixelEditorColor.cropGuide, lineWidth: 1)

      GeometryReader { proxy in
        PixelEditorCropGuideGrid()
          .stroke(PixelEditorColor.cropGuide.opacity(0.3), lineWidth: 1)
          .opacity(isAdjustmentActive ? 1 : 0)

        PixelEditorCropGuideHandles()
          .stroke(
            PixelEditorColor.cropGuide,
            style: StrokeStyle(lineWidth: 3, lineCap: .square, lineJoin: .miter)
          )
          .frame(width: proxy.size.width, height: proxy.size.height)
      }
    }
    .allowsHitTesting(false)
    .animation(.easeInOut(duration: 0.2), value: isAdjustmentActive)
  }
}

private struct PixelEditorCropGuideGrid: Shape {

  func path(in rect: CGRect) -> Path {
    Path { path in
      let oneThirdX = rect.width / 3
      let oneThirdY = rect.height / 3

      for index in 1...2 {
        let x = rect.minX + oneThirdX * CGFloat(index)
        path.move(to: CGPoint(x: x, y: rect.minY))
        path.addLine(to: CGPoint(x: x, y: rect.maxY))

        let y = rect.minY + oneThirdY * CGFloat(index)
        path.move(to: CGPoint(x: rect.minX, y: y))
        path.addLine(to: CGPoint(x: rect.maxX, y: y))
      }
    }
  }
}

private struct PixelEditorCropGuideHandles: Shape {

  func path(in rect: CGRect) -> Path {
    Path { path in
      let length: CGFloat = 20

      path.move(to: rect.origin)
      path.addLine(to: CGPoint(x: rect.minX + length, y: rect.minY))
      path.move(to: rect.origin)
      path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + length))

      path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX - length, y: rect.minY))
      path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + length))

      path.move(to: CGPoint(x: rect.maxX, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.maxX - length, y: rect.maxY))
      path.move(to: CGPoint(x: rect.maxX, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - length))

      path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.minX + length, y: rect.maxY))
      path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - length))
    }
  }
}

private struct PixelEditorControlPanel: View {

  let viewModel: ClassicImageEditViewModel
  @Binding var route: PixelEditorControlRoute
  @Binding var displayedRootPanel: PixelEditorRootPanel

  var body: some View {
    ZStack {
      switch route {
      case .root:
        PixelEditorRootControl(
          viewModel: viewModel,
          displayedPanel: $displayedRootPanel,
          onSelectRoute: showRoute
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))

      case .crop:
        PixelEditorCropControl(
          viewModel: viewModel,
          onCancel: {
            viewModel.endCrop(save: false)
            showRoute(.root)
          },
          onDone: {
            viewModel.endCrop(save: true)
            showRoute(.root)
          }
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))

      case .masking:
        PixelEditorMaskControl(
          viewModel: viewModel,
          onCancel: {
            viewModel.endMasking(save: false)
            showRoute(.root)
          },
          onDone: {
            viewModel.endMasking(save: true)
            showRoute(.root)
          }
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))

      case let .filter(kind):
        PixelEditorFilterControl(
          viewModel: viewModel,
          kind: kind,
          onCancel: {
            viewModel.editingStack.revertEdit()
            showRoute(.root)
          },
          onDone: {
            viewModel.editingStack.takeSnapshot()
            showRoute(.root)
          }
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(.spring(response: 0.32, dampingFraction: 1), value: route)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func showRoute(_ route: PixelEditorControlRoute) {
    withAnimation(.spring(response: 0.32, dampingFraction: 1)) {
      self.route = route
    }
  }
}

private struct PixelEditorRootControl: View {

  let viewModel: ClassicImageEditViewModel
  @Binding var displayedPanel: PixelEditorRootPanel
  let onSelectRoute: (PixelEditorControlRoute) -> Void

  var body: some View {
    VStack(spacing: 0) {
      Group {
        switch displayedPanel {
        case .filter:
          PixelEditorPresetList(viewModel: viewModel)

        case .edit:
          PixelEditorEditMenu(
            viewModel: viewModel,
            onSelectRoute: onSelectRoute
          )
        }
      }
      .frame(height: 118)

      HStack(spacing: 0) {
        Button {
          displayedPanel = .filter
        } label: {
          Text(viewModel.localizedStrings.filter)
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(displayedPanel == .filter ? PixelEditorColor.primary : PixelEditorColor.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityIdentifier("swiftui.pixel.filter")

        Button {
          displayedPanel = .edit
        } label: {
          Text(viewModel.localizedStrings.edit)
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(displayedPanel == .edit ? PixelEditorColor.primary : PixelEditorColor.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityIdentifier("swiftui.pixel.edit")
      }
      .frame(height: 50)
    }
    .onAppear {
      viewModel.setMode(.preview)
    }
  }
}

private struct PixelEditorPresetList: View {

  let viewModel: ClassicImageEditViewModel

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 16) {
          Button {
            setPreset(nil)
          } label: {
            PixelEditorPresetCell(
              title: viewModel.localizedStrings.control_preset_normal_name,
              image: viewModel.editingStack.loadedState?.thumbnailImage,
              isSelected: currentPreset == nil
            )
          }
          .buttonStyle(.plain)
          .id("normal")

          if let previews = viewModel.editingStack.loadedState?.previewFilterPresets {
            ForEach(previews, id: \.filter.identifier) { preview in
              Button {
                setPreset(preview.filter)
              } label: {
                PixelEditorPresetCell(
                  title: preview.filter.name,
                  image: preview.image,
                  isSelected: currentPreset == preview.filter
                )
              }
              .buttonStyle(.plain)
              .id(preview.filter.identifier)
            }
          }
        }
        .padding(.horizontal, 44)
        .frame(minHeight: 100)
      }
      .onAppear {
        scrollToSelection(proxy: proxy)
      }
    }
  }

  private var currentPreset: FilterPreset? {
    viewModel.editingStack.loadedState?.currentEdit.filters.preset
  }

  private func setPreset(_ preset: FilterPreset?) {
    viewModel.editingStack.set(filters: {
      $0.preset = preset
    })
    viewModel.editingStack.takeSnapshot()
  }

  private func scrollToSelection(proxy: ScrollViewProxy) {
    if let currentPreset {
      proxy.scrollTo(currentPreset.identifier, anchor: .center)
    } else {
      proxy.scrollTo("normal", anchor: .center)
    }
  }
}

private struct PixelEditorPresetCell: View {

  let title: String
  let image: CIImage?
  let isSelected: Bool

  var body: some View {
    VStack(spacing: 12) {
      PixelEditorMetalImageView(image: image, contentMode: .scaleAspectFill)
        .frame(width: 64, height: 64)
        .clipped()

      Text(title)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(isSelected ? PixelEditorColor.primary : PixelEditorColor.secondary)
        .lineLimit(1)
        .frame(width: 76)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
  }
}

private struct PixelEditorEditMenu: View {

  let viewModel: ClassicImageEditViewModel
  let onSelectRoute: (PixelEditorControlRoute) -> Void

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 16) {
        ForEach(displayedMenus, id: \.self) { menu in
          Button {
            onSelectRoute(menu.route)
          } label: {
            PixelEditorEditMenuCell(
              title: menu.title(localizedStrings: viewModel.localizedStrings),
              imageName: menu.imageName,
              hasChanges: menu.hasChanges(in: viewModel.editingStack.loadedState?.currentEdit)
            )
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 36)
      .frame(minHeight: 100)
    }
  }

  private var displayedMenus: [ClassicImageEditEditMenu] {
    let control = viewModel.options.classes.control
    return control.editMenus.filter { !control.ignoredEditMenus.contains($0) }
  }
}

private struct PixelEditorEditMenuCell: View {

  let title: String
  let imageName: String
  let hasChanges: Bool

  var body: some View {
    VStack(spacing: 10) {
      ZStack(alignment: .topTrailing) {
        Image(uiImage: UIImage(named: imageName, in: bundle, compatibleWith: nil) ?? UIImage())
          .renderingMode(.template)
          .resizable()
          .scaledToFit()
          .foregroundStyle(PixelEditorColor.primary)
          .frame(width: 50, height: 50)

        if hasChanges {
          Circle()
            .fill(PixelEditorColor.accent)
            .frame(width: 7, height: 7)
            .offset(x: -4, y: 4)
        }
      }

      Text(title)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(PixelEditorColor.secondary)
        .lineLimit(1)
        .frame(width: 76)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
  }
}

private struct PixelEditorCropControl: View {

  let viewModel: ClassicImageEditViewModel
  let onCancel: () -> Void
  let onDone: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 0)
      PixelEditorControlNavigation(
        cancelText: viewModel.localizedStrings.cancel,
        doneText: viewModel.localizedStrings.done,
        onCancel: onCancel,
        onDone: onDone
      )
    }
    .onAppear {
      viewModel.setMode(.crop)
    }
  }
}

private struct PixelEditorMaskControl: View {

  let viewModel: ClassicImageEditViewModel
  let onCancel: () -> Void
  let onDone: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      VStack(spacing: 16) {
        Button(viewModel.localizedStrings.clear) {
          viewModel.editingStack.set(blurringMaskPaths: [])
          viewModel.editingStack.takeSnapshot()
        }
        .font(.system(size: 17, weight: .bold))
        .foregroundStyle(PixelEditorColor.primary)

        HStack(spacing: 10) {
          Text(viewModel.localizedStrings.brushSizeSmall)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(PixelEditorColor.primary)

          PixelEditorStepSlider(
            value: brushSliderValue,
            range: -0.5...0.5,
            mode: .plusAndMinus,
            onChange: { value in
              let position = CGFloat(value + 0.5)
              let size = (5 + position * (50 - 5)).rounded()
              viewModel.setBrushSize(size)
            }
          )
          .frame(height: 44)

          Text(viewModel.localizedStrings.brushSizeLarge)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(PixelEditorColor.primary)
        }
        .padding(.horizontal, 36)

        Circle()
          .stroke(PixelEditorColor.primary, lineWidth: 1)
          .background(Circle().fill(PixelEditorColor.background))
          .frame(width: brushSize, height: brushSize)
          .frame(width: 50, height: 50)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      PixelEditorControlNavigation(
        cancelText: viewModel.localizedStrings.cancel,
        doneText: viewModel.localizedStrings.done,
        onCancel: onCancel,
        onDone: onDone
      )
    }
    .onAppear {
      viewModel.setMode(.masking)
    }
  }

  private var brushSize: CGFloat {
    switch viewModel.maskingBrushSize {
    case let .point(value), let .pixel(value):
      return value
    }
  }

  private var brushSliderValue: Double {
    Double((brushSize - 5) / (50 - 5)) - 0.5
  }
}

private struct PixelEditorFilterControl: View {

  let viewModel: ClassicImageEditViewModel
  let kind: PixelEditorFilterKind
  let onCancel: () -> Void
  let onDone: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      PixelEditorStepSlider(
        value: kind.value(in: viewModel.editingStack.loadedState?.currentEdit.filters),
        range: kind.range,
        mode: kind.sliderMode,
        onChange: {
          kind.setValue($0, editingStack: viewModel.editingStack)
        }
      )
      .frame(height: 44)
      .padding(.horizontal, PixelEditorLayout.controlHorizontalMargin)
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      PixelEditorControlNavigation(
        cancelText: viewModel.localizedStrings.cancel,
        doneText: viewModel.localizedStrings.done,
        onCancel: onCancel,
        onDone: onDone
      )
    }
    .onAppear {
      viewModel.setMode(.editing)
      viewModel.setTitle(kind.title(localizedStrings: viewModel.localizedStrings))
    }
  }
}

private struct PixelEditorStepSlider: View {

  enum Mode: Hashable {
    case plus
    case plusAndMinus
    case minus
  }

  let value: Double
  let range: ClosedRange<Double>
  let mode: Mode
  let onChange: (Double) -> Void

  var body: some View {
    PixelEditorPrecisionLevelSlider(
      value: positionBinding,
      haptics: .init(trigger: { position in
        step(forPosition: position) == 0 ? .selection : nil
      }),
      range: .init(
        range: mode.positionRange,
        transform: { position in
          sliderPosition(forEditingValue: editingValue(forPosition: position))
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
      track: { position, _ in
        PixelEditorStepSliderTickTrack(value: position)
      }
    )
    .tint(PixelEditorColor.primary)
    .id(mode)
  }

  private var positionBinding: Binding<Double> {
    Binding(
      get: {
        sliderPosition(forEditingValue: value)
      },
      set: { position in
        let newValue = editingValue(forPosition: position)
        guard newValue != value else { return }
        onChange(newValue)
      }
    )
  }

  private func sliderPosition(forEditingValue value: Double) -> Double {
    guard value != 0 else { return 0 }

    if value > 0 {
      guard range.upperBound != 0 else { return 0 }
      let ratio = (value / range.upperBound).clamped(to: 0...1)
      return PixelEditorStepSliderMetrics.deadZone + ratio * (mode.positionRange.upperBound - PixelEditorStepSliderMetrics.deadZone)
    } else {
      guard range.lowerBound != 0 else { return 0 }
      let ratio = (value / range.lowerBound).clamped(to: 0...1)
      return -PixelEditorStepSliderMetrics.deadZone + ratio * (mode.positionRange.lowerBound + PixelEditorStepSliderMetrics.deadZone)
    }
  }

  private func editingValue(forPosition position: Double) -> Double {
    if (-PixelEditorStepSliderMetrics.deadZone...PixelEditorStepSliderMetrics.deadZone).contains(position) {
      return 0
    }

    if position > 0 {
      let ratio = ((position - PixelEditorStepSliderMetrics.deadZone) / (mode.positionRange.upperBound - PixelEditorStepSliderMetrics.deadZone))
        .clamped(to: 0...1)
      let step = (ratio * Double(mode.maxStep)).rounded()
      return range.upperBound * step / Double(mode.maxStep)
    } else {
      let ratio = ((position + PixelEditorStepSliderMetrics.deadZone) / (mode.positionRange.lowerBound + PixelEditorStepSliderMetrics.deadZone))
        .clamped(to: 0...1)
      let step = (ratio * Double(abs(mode.minStep))).rounded()
      return range.lowerBound * step / Double(abs(mode.minStep))
    }
  }

  private func step(for value: Double) -> Int {
    let step: Int

    if value > 0 {
      guard range.upperBound != 0 else { return 0 }
      step = Int((value / range.upperBound * Double(mode.maxStep)).rounded())
    } else if value < 0 {
      guard range.lowerBound != 0 else { return 0 }
      step = -Int((value / range.lowerBound * Double(abs(mode.minStep))).rounded())
    } else {
      step = 0
    }

    return step
  }

  private func step(forPosition position: Double) -> Int {
    step(for: editingValue(forPosition: position))
  }
}

private struct PixelEditorPrecisionLevelSlider<CenterLevel: View, Track: View>: UIViewRepresentable {

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

private enum PixelEditorStepSliderMetrics {
  static let deadZone: Double = 0.05
}

private struct PixelEditorStepSliderTickTrack: View {

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
          PixelEditorStepSliderShortBar()
            .foregroundStyle(.primary)
          Group {
            Spacer(minLength: 0)
            PixelEditorStepSliderShortBar()
            Spacer(minLength: 0)
            PixelEditorStepSliderShortBar()
            Spacer(minLength: 0)
            PixelEditorStepSliderShortBar()
            Spacer(minLength: 0)
            PixelEditorStepSliderShortBar()
            Spacer(minLength: 0)
            PixelEditorStepSliderShortBar()
            Spacer(minLength: 0)
            PixelEditorStepSliderShortBar()
            Spacer(minLength: 0)
            PixelEditorStepSliderShortBar()
            Spacer(minLength: 0)
            PixelEditorStepSliderShortBar()
            Spacer(minLength: 0)
            PixelEditorStepSliderShortBar()
            Spacer(minLength: 0)
          }
          .foregroundStyle(.secondary)
        }
        PixelEditorStepSliderShortBar()
          .foregroundStyle(.primary)
      }
    }
    .foregroundStyle(.tint)
  }
}

private struct PixelEditorStepSliderShortBar: View {
  var body: some View {
    RoundedRectangle(cornerRadius: 8)
      .frame(width: 1, height: 10)
  }
}

private extension PixelEditorStepSlider.Mode {

  var positionRange: ClosedRange<Double> {
    switch self {
    case .plus:
      return 0...1
    case .plusAndMinus:
      return -1...1
    case .minus:
      return -1...0
    }
  }

  var minStep: Int {
    switch self {
    case .plus:
      return 0
    case .plusAndMinus, .minus:
      return -100
    }
  }

  var maxStep: Int {
    switch self {
    case .plus, .plusAndMinus:
      return 100
    case .minus:
      return 0
    }
  }
}

private struct PixelEditorControlNavigation: View {

  let cancelText: String
  let doneText: String
  let onCancel: () -> Void
  let onDone: () -> Void

  var body: some View {
    HStack(spacing: 0) {
      Button(cancelText, action: onCancel)
        .font(.system(size: 17, weight: .regular))
        .foregroundStyle(PixelEditorColor.primary)
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("swiftui.pixel.control.cancel")

      Button(doneText, action: onDone)
        .font(.system(size: 17, weight: .bold))
        .foregroundStyle(PixelEditorColor.primary)
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("swiftui.pixel.control.done")
    }
    .frame(height: 50)
  }
}

private struct PixelEditorImagePreviewRepresentable: UIViewRepresentable {

  let editingStack: EditingStack
  let displayBackground: MetalImageView.DisplayBackground

  func makeUIView(context: Context) -> ImagePreviewView {
    let view = ImagePreviewView(editingStack: editingStack)
    view.displayBackground = displayBackground
    return view
  }

  func updateUIView(_ uiView: ImagePreviewView, context: Context) {
    uiView.displayBackground = displayBackground
  }
}

private struct PixelEditorMetalImageView: UIViewRepresentable {

  let image: CIImage?
  let contentMode: UIView.ContentMode

  func makeUIView(context: Context) -> MetalImageView {
    let view = MetalImageView()
    view.clipsToBounds = true
    view.contentMode = contentMode
    view.displayBackground = .color(.systemBackground)
    return view
  }

  func updateUIView(_ uiView: MetalImageView, context: Context) {
    uiView.contentMode = contentMode
    uiView.displayBackground = .color(.systemBackground)
    uiView.display(image: image)
  }
}

private extension ClassicImageEditViewModel.Mode {

  var isCrop: Bool {
    switch self {
    case .crop:
      return true
    case .masking, .editing, .preview:
      return false
    }
  }

  var isMasking: Bool {
    switch self {
    case .masking:
      return true
    case .crop, .editing, .preview:
      return false
    }
  }

  var isEditing: Bool {
    switch self {
    case .editing:
      return true
    case .crop, .masking, .preview:
      return false
    }
  }

  var displaysMaskingView: Bool {
    switch self {
    case .masking, .preview:
      return true
    case .crop, .editing:
      return false
    }
  }
}

private extension ClassicImageEditEditMenu {

  var route: PixelEditorControlRoute {
    switch self {
    case .adjustment:
      return .crop
    case .mask:
      return .masking
    case .exposure:
      return .filter(.exposure)
    case .gaussianBlur:
      return .filter(.gaussianBlur)
    case .contrast:
      return .filter(.contrast)
    case .temperature:
      return .filter(.temperature)
    case .saturation:
      return .filter(.saturation)
    case .highlights:
      return .filter(.highlights)
    case .shadows:
      return .filter(.shadows)
    case .vignette:
      return .filter(.vignette)
    case .fade:
      return .filter(.fade)
    case .sharpen:
      return .filter(.sharpen)
    case .clarity:
      return .filter(.clarity)
    }
  }

  var imageName: String {
    switch self {
    case .adjustment:
      return "adjustment"
    case .mask:
      return "mask"
    case .exposure:
      return "brightness"
    case .gaussianBlur:
      return "blur"
    case .contrast:
      return "contrast"
    case .temperature:
      return "temperature"
    case .saturation:
      return "saturation"
    case .highlights:
      return "highlights"
    case .shadows:
      return "shadows"
    case .vignette:
      return "vignette"
    case .fade:
      return "fade"
    case .sharpen:
      return "sharpen"
    case .clarity:
      return "structure"
    }
  }

  func title(localizedStrings: ClassicImageEditViewController.LocalizedStrings) -> String {
    switch self {
    case .adjustment:
      return localizedStrings.editAdjustment
    case .mask:
      return localizedStrings.editMask
    case .exposure:
      return localizedStrings.editBrightness
    case .gaussianBlur:
      return localizedStrings.editBlur
    case .contrast:
      return localizedStrings.editContrast
    case .temperature:
      return localizedStrings.editTemperature
    case .saturation:
      return localizedStrings.editSaturation
    case .highlights:
      return localizedStrings.editHighlights
    case .shadows:
      return localizedStrings.editShadows
    case .vignette:
      return localizedStrings.editVignette
    case .fade:
      return localizedStrings.editFade
    case .sharpen:
      return localizedStrings.editSharpen
    case .clarity:
      return localizedStrings.editClarity
    }
  }

  func hasChanges(in edit: EditingStack.Edit?) -> Bool {
    guard let edit else {
      return false
    }

    switch self {
    case .adjustment:
      return false
    case .mask:
      return !edit.drawings.blurredMaskPaths.isEmpty
    case .exposure:
      return edit.filters.exposure != nil
    case .gaussianBlur:
      return edit.filters.gaussianBlur != nil
    case .contrast:
      return edit.filters.contrast != nil
    case .temperature:
      return edit.filters.temperature != nil
    case .saturation:
      return edit.filters.saturation != nil
    case .highlights:
      return edit.filters.highlights != nil
    case .shadows:
      return edit.filters.shadows != nil
    case .vignette:
      return edit.filters.vignette != nil
    case .fade:
      return edit.filters.fade != nil
    case .sharpen:
      return edit.filters.sharpen != nil
    case .clarity:
      return edit.filters.unsharpMask != nil
    }
  }
}

private extension PixelEditorFilterKind {

  var range: ClosedRange<Double> {
    switch self {
    case .exposure:
      return FilterExposure.range.min...FilterExposure.range.max
    case .gaussianBlur:
      return FilterGaussianBlur.range.min...FilterGaussianBlur.range.max
    case .contrast:
      return FilterContrast.range.min...FilterContrast.range.max
    case .temperature:
      return FilterTemperature.range.min...FilterTemperature.range.max
    case .saturation:
      return FilterSaturation.range.min...FilterSaturation.range.max
    case .highlights:
      return FilterHighlights.range.min...FilterHighlights.range.max
    case .shadows:
      return FilterShadows.range.min...FilterShadows.range.max
    case .vignette:
      return FilterVignette.range.min...FilterVignette.range.max
    case .fade:
      return FilterFade.Params.intensity.min...FilterFade.Params.intensity.max
    case .sharpen:
      return FilterSharpen.Params.sharpness.min...FilterSharpen.Params.sharpness.max
    case .clarity:
      return FilterUnsharpMask.Params.intensity.min...FilterUnsharpMask.Params.intensity.max
    }
  }

  var sliderMode: PixelEditorStepSlider.Mode {
    switch self {
    case .gaussianBlur, .highlights, .vignette, .fade, .sharpen, .clarity:
      return .plus
    case .exposure, .contrast, .temperature, .saturation, .shadows:
      return .plusAndMinus
    }
  }

  func title(localizedStrings: ClassicImageEditViewController.LocalizedStrings) -> String {
    switch self {
    case .exposure:
      return localizedStrings.editBrightness
    case .gaussianBlur:
      return localizedStrings.editBlur
    case .contrast:
      return localizedStrings.editContrast
    case .temperature:
      return localizedStrings.editTemperature
    case .saturation:
      return localizedStrings.editSaturation
    case .highlights:
      return localizedStrings.editHighlights
    case .shadows:
      return localizedStrings.editShadows
    case .vignette:
      return localizedStrings.editVignette
    case .fade:
      return localizedStrings.editFade
    case .sharpen:
      return localizedStrings.editSharpen
    case .clarity:
      return localizedStrings.editClarity
    }
  }

  func value(in filters: EditingStack.Edit.Filters?) -> Double {
    guard let filters else {
      return 0
    }

    switch self {
    case .exposure:
      return filters.exposure?.value ?? 0
    case .gaussianBlur:
      return filters.gaussianBlur?.value ?? 0
    case .contrast:
      return filters.contrast?.value ?? 0
    case .temperature:
      return filters.temperature?.value ?? 0
    case .saturation:
      return filters.saturation?.value ?? 0
    case .highlights:
      return filters.highlights?.value ?? 0
    case .shadows:
      return filters.shadows?.value ?? 0
    case .vignette:
      return filters.vignette?.value ?? 0
    case .fade:
      return filters.fade?.intensity ?? 0
    case .sharpen:
      return filters.sharpen?.sharpness ?? 0
    case .clarity:
      return filters.unsharpMask?.intensity ?? 0
    }
  }

  func setValue(_ value: Double, editingStack: EditingStack) {
    editingStack.set(filters: { filters in
      switch self {
      case .exposure:
        filters.exposure = value.nonZeroFilter { FilterExposure(value: $0) }
      case .gaussianBlur:
        filters.gaussianBlur = value.nonZeroFilter { FilterGaussianBlur(value: $0) }
      case .contrast:
        filters.contrast = value.nonZeroFilter { FilterContrast(value: $0) }
      case .temperature:
        filters.temperature = value.nonZeroFilter { FilterTemperature(value: $0) }
      case .saturation:
        filters.saturation = value.nonZeroFilter { FilterSaturation(value: $0) }
      case .highlights:
        filters.highlights = value.nonZeroFilter { FilterHighlights(value: $0) }
      case .shadows:
        filters.shadows = value.nonZeroFilter { FilterShadows(value: $0) }
      case .vignette:
        filters.vignette = value.nonZeroFilter { FilterVignette(value: $0) }
      case .fade:
        filters.fade = value.nonZeroFilter { FilterFade(intensity: $0) }
      case .sharpen:
        filters.sharpen = value.nonZeroFilter {
          var filter = FilterSharpen()
          filter.sharpness = $0
          filter.radius = 1.2
          return filter
        }
      case .clarity:
        filters.unsharpMask = value.nonZeroFilter {
          var filter = FilterUnsharpMask()
          filter.intensity = $0
          filter.radius = 0.12
          return filter
        }
      }
    })
  }
}

private extension Double {

  func clamped(to range: ClosedRange<Double>) -> Double {
    min(max(self, range.lowerBound), range.upperBound)
  }

  func nonZeroFilter<Filter>(_ makeFilter: (Double) -> Filter) -> Filter? {
    guard self != 0 else {
      return nil
    }
    return makeFilter(self)
  }
}

private extension ClosedRange where Bound == Double {

  var length: Double {
    upperBound - lowerBound
  }
}

private extension FilterExposure {
  init(value: Double) {
    self.init()
    self.value = value
  }
}

private extension FilterGaussianBlur {
  init(value: Double) {
    self.init()
    self.value = value
  }
}

private extension FilterContrast {
  init(value: Double) {
    self.init()
    self.value = value
  }
}

private extension FilterTemperature {
  init(value: Double) {
    self.init()
    self.value = value
  }
}

private extension FilterSaturation {
  init(value: Double) {
    self.init()
    self.value = value
  }
}

private extension FilterHighlights {
  init(value: Double) {
    self.init()
    self.value = value
  }
}

private extension FilterShadows {
  init(value: Double) {
    self.init()
    self.value = value
  }
}

private extension FilterVignette {
  init(value: Double) {
    self.init()
    self.value = value
  }
}

private extension FilterFade {
  init(intensity: Double) {
    self.init()
    self.intensity = intensity
  }
}
