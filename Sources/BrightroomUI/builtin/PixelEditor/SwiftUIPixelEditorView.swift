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
import SwiftUI
import UIKit

import BrightroomEngine

public struct SwiftUIPixelEditorView: View {

  @State private var viewModel: PixelEditorViewModel
  @State private var controlRoute: PixelEditorControlRoute = .root
  @State private var displayedRootPanel: PixelEditorRootPanel = .filter

  private let onEndEditing: (EditingStack) -> Void
  private let onCancelEditing: () -> Void

  public init(
    editingStack: EditingStack,
    options: PixelEditorOptions = .default,
    localizedStrings: PixelEditorLocalizedStrings = .init(),
    onEndEditing: @escaping (EditingStack) -> Void = { _ in },
    onCancelEditing: @escaping () -> Void = {}
  ) {
    self._viewModel = State(
      initialValue: PixelEditorViewModel(
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
      let canvasLength = min(
        proxy.size.width,
        max(0, proxy.size.height - PixelEditorLayout.topBarHeight - PixelEditorLayout.controlPanelHeight)
      )

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
          .frame(width: canvasLength, height: canvasLength)
          .frame(maxWidth: .infinity, maxHeight: .infinity)

        PixelEditorControlPanel(
          viewModel: viewModel,
          route: $controlRoute,
          displayedRootPanel: $displayedRootPanel
        )
        .frame(height: PixelEditorLayout.controlPanelHeight)
      }
      .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(PixelEditorColor.background)
    .task {
      viewModel.startEditingStack()
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
  static let controlPanelHeight: CGFloat = 168
  static let previewButtonHeight: CGFloat = 32
  static let horizontalMargin: CGFloat = 20
  static let controlHorizontalMargin: CGFloat = 44
}

private enum PixelEditorControlAnimation {
  static let panelChange = Animation.spring(response: 0.28, dampingFraction: 0.92)
  static let blurRadius: CGFloat = 5
  static let slideDistance: CGFloat = 12
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

  let mode: PixelEditorViewModel.Mode
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
    .pixelEditorContainerCornerOffset(.horizontal, sizeToFit: true)
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

private extension View {

  @ViewBuilder
  func pixelEditorContainerCornerOffset(_ edges: Edge.Set, sizeToFit: Bool = false) -> some View {
#if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      self.containerCornerOffset(edges, sizeToFit: sizeToFit)
    } else {
      self
    }
#else
    self
#endif
  }

  func pixelEditorControlPresentation(
    isVisible: Bool,
    hiddenOffsetY: CGFloat = PixelEditorControlAnimation.slideDistance
  ) -> some View {
    self
      .opacity(isVisible ? 1 : 0)
      .blur(radius: isVisible ? 0 : PixelEditorControlAnimation.blurRadius)
      .offset(y: isVisible ? 0 : hiddenOffsetY)
      .animation(PixelEditorControlAnimation.panelChange, value: isVisible)
  }
}

private struct PixelEditorCanvas: View {

  let viewModel: PixelEditorViewModel

  var body: some View {
    let _ = viewModel.editingStackObservationVersion

    GeometryReader { proxy in
      ZStack {
        SwiftUICropView(
          editingStack: viewModel.editingStack,
          isGuideInteractionEnabled: isGuideInteractionEnabled,
          isAutoApplyEditingStackEnabled: false,
          contentInset: .zero,
          cropInsideOverlay: { adjustmentKind in
            if viewModel.mode.isCrop && viewModel.options.croppingAspectRatio == nil {
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
        .displayMode(.renderedEditPreview)
        .surfaceMode(surfaceMode)
        .brush(canvasBrush(in: proxy.size))
        .strokeSmoothing(.init())
        .registerApplyAction(viewModel.cropApplyAction)

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

  private var surfaceMode: CropViewSurfaceMode {
    switch viewModel.mode {
    case .crop:
      return .crop
    case .masking:
      return .masking(maskingEffect)
    case .editing, .preview:
      return .viewing
    }
  }

  private var isGuideInteractionEnabled: Bool {
    viewModel.mode.isCrop && viewModel.options.croppingAspectRatio == nil
  }

  private var maskingEffect: EditingStack.Edit.LocalAdjustmentEffect {
    guard let crop = viewModel.editingStack.loadedState?.currentEdit.crop else {
      return .gaussianBlur(radius: 18)
    }

    let diagonalLength = hypot(crop.cropExtent.width, crop.cropExtent.height)
    return .gaussianBlur(radius: max(diagonalLength / 50, 1))
  }

  private func canvasBrush(in viewportSize: CGSize) -> EditingCanvasBrush {
    .init(
      size: Double(imageSpaceBrushSize(in: viewportSize)),
      hardness: 0.72,
      opacity: 0.9,
      spacing: 0.18
    )
  }

  private func imageSpaceBrushSize(in viewportSize: CGSize) -> CGFloat {
    switch viewModel.maskingBrushSize {
    case let .pixel(value):
      return value
    case let .point(value):
      guard
        let crop = viewModel.editingStack.loadedState?.currentEdit.crop,
        viewportSize.width > 0,
        viewportSize.height > 0,
        crop.cropExtent.width > 0,
        crop.cropExtent.height > 0
      else {
        return value
      }

      let fitScale = min(
        viewportSize.width / crop.cropExtent.width,
        viewportSize.height / crop.cropExtent.height
      )
      return value / max(fitScale, 0.0001)
    }
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

  let viewModel: PixelEditorViewModel
  @Binding var route: PixelEditorControlRoute
  @Binding var displayedRootPanel: PixelEditorRootPanel

  @State private var presentedDetailRoute: PixelEditorControlRoute?
  @State private var isDetailControlVisible = false
  @State private var detailEntryRevision: EditingStack.Revision?
  @State private var detailSessionID = 0

  var body: some View {
    ZStack(alignment: .bottom) {
      PixelEditorRootControl(
        viewModel: viewModel,
        displayedPanel: $displayedRootPanel,
        onSelectRoute: showRoute
      )
      .pixelEditorControlPresentation(isVisible: !isDetailControlVisible)
      .allowsHitTesting(route == .root)
      .accessibilityHidden(route != .root)

      if let presentedDetailRoute {
        detailControl(for: presentedDetailRoute)
          .id(detailSessionID)
          .pixelEditorControlPresentation(isVisible: isDetailControlVisible)
          .allowsHitTesting(route != .root)
          .accessibilityHidden(route == .root)
      }
    }
    .onAppear {
      configureMode(for: route)
      updatePresentedControl(for: route, animated: false)
    }
    .onChange(of: route) { _, newRoute in
      configureMode(for: newRoute)
      updatePresentedControl(for: newRoute, animated: true)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
  }

  @ViewBuilder
  private func detailControl(for route: PixelEditorControlRoute) -> some View {
    switch route {
    case .root:
      EmptyView()

    case .crop:
      PixelEditorCropControl(
        viewModel: viewModel,
        onCancel: {
          viewModel.endCrop(save: false)
          finishDetailEditing()
          showRoute(.root)
        },
        onDone: {
          viewModel.endCrop(save: true)
          finishDetailEditing()
          showRoute(.root)
        }
      )

    case .masking:
      PixelEditorMaskControl(
        viewModel: viewModel,
        onCancel: {
          restoreDetailEntryRevision()
          showRoute(.root)
        },
        onDone: {
          viewModel.endMasking(save: true)
          finishDetailEditing()
          showRoute(.root)
        }
      )

    case let .filter(kind):
      PixelEditorFilterControl(
        viewModel: viewModel,
        kind: kind,
        onCancel: {
          restoreDetailEntryRevision()
          showRoute(.root)
        },
        onDone: {
          viewModel.editingStack.takeSnapshot()
          finishDetailEditing()
          showRoute(.root)
        }
      )
    }
  }

  private func showRoute(_ route: PixelEditorControlRoute) {
    self.route = route
  }

  private func configureMode(for route: PixelEditorControlRoute) {
    switch route {
    case .root:
      viewModel.setMode(.preview)

    case .crop:
      viewModel.setMode(.crop)

    case .masking:
      viewModel.setMode(.masking)

    case let .filter(kind):
      viewModel.setMode(.editing)
      viewModel.setTitle(kind.title(localizedStrings: viewModel.localizedStrings))
    }
  }

  private func updatePresentedControl(for route: PixelEditorControlRoute, animated: Bool) {
    switch route {
    case .root:
      setDetailControlVisible(false, animated: animated)

    case .crop:
      if route != presentedDetailRoute || !isDetailControlVisible {
        detailEntryRevision = nil
        detailSessionID += 1
      }
      presentedDetailRoute = route
      setDetailControlVisible(true, animated: animated)

    case .masking, .filter(_):
      if route != presentedDetailRoute || !isDetailControlVisible {
        detailEntryRevision = viewModel.editingStack.currentRevision
        detailSessionID += 1
      }
      presentedDetailRoute = route
      setDetailControlVisible(true, animated: animated)
    }
  }

  private func restoreDetailEntryRevision() {
    if let detailEntryRevision {
      viewModel.editingStack.revert(to: detailEntryRevision)
    } else {
      viewModel.editingStack.revertEdit()
    }
    finishDetailEditing()
  }

  private func finishDetailEditing() {
    detailEntryRevision = nil
  }

  private func setDetailControlVisible(_ isVisible: Bool, animated: Bool) {
    if animated {
      withAnimation(PixelEditorControlAnimation.panelChange) {
        isDetailControlVisible = isVisible
      }
    } else {
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        isDetailControlVisible = isVisible
      }
    }
  }
}

private struct PixelEditorRootControl: View {

  let viewModel: PixelEditorViewModel
  @Binding var displayedPanel: PixelEditorRootPanel
  let onSelectRoute: (PixelEditorControlRoute) -> Void

  var body: some View {
    VStack(spacing: 0) {
      ZStack {
        PixelEditorPresetList(viewModel: viewModel)
          .pixelEditorControlPresentation(isVisible: displayedPanel == .filter, hiddenOffsetY: 6)
          .allowsHitTesting(displayedPanel == .filter)
          .accessibilityHidden(displayedPanel != .filter)

        PixelEditorEditMenuView(
          viewModel: viewModel,
          onSelectRoute: onSelectRoute
        )
        .pixelEditorControlPresentation(isVisible: displayedPanel == .edit, hiddenOffsetY: 6)
        .allowsHitTesting(displayedPanel == .edit)
        .accessibilityHidden(displayedPanel != .edit)
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
  }
}

private struct PixelEditorPresetList: View {

  let viewModel: PixelEditorViewModel

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
          .accessibilityIdentifier("swiftui.pixel.preset.normal")
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
              .accessibilityIdentifier("swiftui.pixel.preset.\(preview.filter.name)")
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
      SwiftUIMetalImageView(
        image: image,
        contentMode: .scaleAspectFill,
        displayBackground: .color(.systemBackground)
      )
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

private struct PixelEditorEditMenuView: View {

  let viewModel: PixelEditorViewModel
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
          .accessibilityIdentifier("swiftui.pixel.menu.\(menu.accessibilityIdentifier)")
        }
      }
      .padding(.horizontal, 36)
      .frame(minHeight: 100)
    }
  }

  private var displayedMenus: [PixelEditorEditMenu] {
    viewModel.options.editMenus.filter { !viewModel.options.ignoredEditMenus.contains($0) }
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

  let viewModel: PixelEditorViewModel
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
  }
}

private struct PixelEditorMaskControl: View {

  let viewModel: PixelEditorViewModel
  let onCancel: () -> Void
  let onDone: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      VStack(spacing: 16) {
        Circle()
          .fill(PixelEditorColor.primary)
          .stroke(PixelEditorColor.primary, lineWidth: 1)
          .background(Circle().fill(PixelEditorColor.background))
          .frame(width: brushSize, height: brushSize)
          .frame(width: 50, height: 50)

        PixelEditorBrushSizeSlider(
          value: brushSize,
          onChange: { size in
            viewModel.setBrushSize(size)
          }
        )
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .padding(.horizontal, 36)

        Button(viewModel.localizedStrings.clear) {
          viewModel.editingStack.set(localAdjustments: [])
          viewModel.editingStack.set(blurringMaskPaths: [])
          viewModel.editingStack.takeSnapshot()
        }
        .font(.system(size: 17, weight: .bold))
        .foregroundStyle(PixelEditorColor.primary)
        .accessibilityIdentifier("swiftui.pixel.mask.clear")
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      PixelEditorControlNavigation(
        cancelText: viewModel.localizedStrings.cancel,
        doneText: viewModel.localizedStrings.done,
        onCancel: onCancel,
        onDone: onDone
      )
    }
  }

  private var brushSize: CGFloat {
    switch viewModel.maskingBrushSize {
    case let .point(value), let .pixel(value):
      return value
    }
  }

}

private struct PixelEditorBrushSizeSlider: View {

  let value: CGFloat
  let onChange: (CGFloat) -> Void

  var body: some View {
    BrightroomSteppedSlider(
      value: valueBinding,
      range: PixelEditorBrushSizeMetrics.sizeRange,
      stepCount: PixelEditorBrushSizeMetrics.stepCount,
      style: .pixelEditorStepSlider,
      transform: { value in
        value.rounded()
      },
      hapticIdentity: { _ in nil },
      onHaptic: {},
      topMarker: { _ in
        Color.clear
          .frame(width: 6, height: 6)
      },
      tick: { context in
        Capsule()
          .foregroundStyle(context.isMajor ? Color.primary : Color.secondary)
      }
    )
    .tint(PixelEditorColor.primary)
  }

  private var valueBinding: Binding<Double> {
    Binding(
      get: {
        Double(value)
          .clamped(to: PixelEditorBrushSizeMetrics.sizeRange)
      },
      set: { newValue in
        let newSize = CGFloat(newValue.rounded())
        guard newSize != value else { return }
        onChange(newSize)
      }
    )
  }
}

private enum PixelEditorBrushSizeMetrics {
  static let minimumSize: Double = 5
  static let maximumSize: Double = 50
  static let sizeRange = minimumSize...maximumSize
  static let stepCount = Int(maximumSize - minimumSize)
}

private struct PixelEditorFilterControl: View {

  let viewModel: PixelEditorViewModel
  let kind: PixelEditorFilterKind
  let onCancel: () -> Void
  let onDone: () -> Void

  var body: some View {
    let displayValue = kind.displayValue(in: viewModel.editingStack.loadedState?.currentEdit.filters)

    VStack(spacing: 0) {
      VStack(spacing: 8) {
        Text(displayText(for: displayValue))
          .font(.system(size: 13, weight: .semibold, design: .monospaced))
          .foregroundStyle(PixelEditorColor.primary)
          .frame(minWidth: 42)

        PixelEditorStepSlider(
          value: displayValue,
          range: PixelEditorAdjustmentSliderMetrics.displayRange,
          mode: kind.sliderMode,
          onChange: {
            kind.setDisplayValue($0, editingStack: viewModel.editingStack)
          }
        )
        .frame(height: 44)
      }
      .padding(.horizontal, PixelEditorLayout.controlHorizontalMargin)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityIdentifier("swiftui.pixel.filter.\(kind.accessibilityIdentifier)")

      PixelEditorControlNavigation(
        cancelText: viewModel.localizedStrings.cancel,
        doneText: viewModel.localizedStrings.done,
        onCancel: onCancel,
        onDone: onDone
      )
    }
  }

  private func displayText(for value: Double) -> String {
    let roundedValue = Int(value.rounded())
    if roundedValue > 0 {
      return "+\(roundedValue)"
    } else {
      return "\(roundedValue)"
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
    let currentPosition = sliderPosition(forEditingValue: value)
    let currentStep = step(forPosition: currentPosition)
    let showsOriginMarker = currentStep != 0

    BrightroomSteppedSlider(
      value: positionBinding,
      range: mode.positionRange,
      stepCount: mode.tickCount,
      style: .pixelEditorStepSlider,
      resetValue: mode.originPosition,
      transform: { position in
        sliderPosition(forEditingValue: editingValue(forPosition: position))
      },
      hapticIdentity: { _ in nil },
      onHaptic: {},
      topMarker: { context in
        Circle()
          .frame(width: 6, height: 6)
          .opacity(context.isOrigin(in: mode) && showsOriginMarker ? 1 : 0)
          .animation(.smooth, value: showsOriginMarker)
      },
      tick: { context in
        Capsule()
          .foregroundStyle(context.isMajor ? Color.primary : Color.secondary)
      }
    )
    .tint(PixelEditorColor.primary)
    .sensoryFeedback(.selection, trigger: currentStep) { _, newStep in
      newStep == 0
    }
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
    sliderPosition(forStep: step(for: value))
  }

  private func editingValue(forPosition position: Double) -> Double {
    let step = step(forSliderPosition: position)
    guard step != 0 else {
      return 0
    }

    if step > 0 {
      guard mode.maxStep > 0 else { return 0 }
      return range.upperBound * Double(step) / Double(mode.maxStep)
    } else {
      guard mode.minStep < 0 else { return 0 }
      return range.lowerBound * Double(abs(step)) / Double(abs(mode.minStep))
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
    step(forSliderPosition: position)
  }

  private func step(forSliderPosition position: Double) -> Int {
    if (mode.originPosition - originSnapRadius...mode.originPosition + originSnapRadius).contains(position) {
      return 0
    }

    if position > mode.originPosition {
      guard mode.maxStep > 0 else { return 0 }
      let distance = mode.positionRange.upperBound - mode.originPosition
      guard distance > 0 else { return 0 }
      let ratio = ((position - mode.originPosition) / distance).clamped(to: 0...1)
      return Int((ratio * Double(mode.maxStep)).rounded())
        .clamped(to: 0...mode.maxStep)
    } else {
      guard mode.minStep < 0 else { return 0 }
      let distance = mode.originPosition - mode.positionRange.lowerBound
      guard distance > 0 else { return 0 }
      let ratio = ((mode.originPosition - position) / distance).clamped(to: 0...1)
      let step = Int((ratio * Double(abs(mode.minStep))).rounded())
        .clamped(to: 0...abs(mode.minStep))
      return -step
    }
  }

  private func sliderPosition(forStep step: Int) -> Double {
    if step > 0 {
      guard mode.maxStep > 0 else { return mode.originPosition }
      let distance = mode.positionRange.upperBound - mode.originPosition
      return mode.originPosition + distance * Double(step) / Double(mode.maxStep)
    } else if step < 0 {
      guard mode.minStep < 0 else { return mode.originPosition }
      let distance = mode.originPosition - mode.positionRange.lowerBound
      return mode.originPosition - distance * Double(abs(step)) / Double(abs(mode.minStep))
    } else {
      return mode.originPosition
    }
  }

  private var originSnapRadius: Double {
    let unitDistances = [
      mode.maxStep > 0 ? (mode.positionRange.upperBound - mode.originPosition) / Double(mode.maxStep) : nil,
      mode.minStep < 0 ? (mode.originPosition - mode.positionRange.lowerBound) / Double(abs(mode.minStep)) : nil,
    ].compactMap { $0 }

    guard let unitDistance = unitDistances.min() else {
      return PixelEditorStepSliderMetrics.originSnapEpsilon
    }

    return unitDistance * PixelEditorStepSliderMetrics.originSnapStepRatio + PixelEditorStepSliderMetrics.originSnapEpsilon
  }
}

private enum PixelEditorStepSliderMetrics {
  static let originSnapStepRatio: Double = 0.5
  static let originSnapEpsilon: Double = 0.000_1
}

private enum PixelEditorAdjustmentSliderMetrics {
  static let displayRange: ClosedRange<Double> = -100...100
}

private extension BrightroomSteppedSliderStyle {
  static let pixelEditorStepSlider = BrightroomSteppedSliderStyle(
    tickWidth: 2,
    tickSpacing: 4,
    tickHeight: 10,
    activeTickWidth: 3,
    activeTickHeight: 18,
    majorTickInterval: 10
  )
}

private extension BrightroomSteppedSliderTickContext {
  func isOrigin(in mode: PixelEditorStepSlider.Mode) -> Bool {
    abs(value - mode.originPosition) < 0.000_001
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

  var originPosition: Double {
    switch self {
    case .plus, .plusAndMinus, .minus:
      return 0
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

  var tickCount: Int {
    abs(minStep) + abs(maxStep)
  }
}

#if DEBUG
#Preview("PixelEditor Step Slider") {
  PixelEditorStepSliderPreview()
}

private struct PixelEditorStepSliderPreview: View {

  @State private var plusValue: Double = 0
  @State private var plusAndMinusValue: Double = 0.24
  @State private var minusValue: Double = -0.24

  var body: some View {
    VStack(spacing: 24) {
      previewItem(
        title: "Plus",
        value: $plusValue,
        range: 0...1,
        mode: .plus
      )

      previewItem(
        title: "Plus and Minus",
        value: $plusAndMinusValue,
        range: -1...1,
        mode: .plusAndMinus
      )

      previewItem(
        title: "Minus",
        value: $minusValue,
        range: -1...0,
        mode: .minus
      )
    }
    .padding(24)
    .frame(width: 520)
    .background(Color(uiColor: .systemBackground))
  }

  private func previewItem(
    title: String,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    mode: PixelEditorStepSlider.Mode
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(title)
          .font(.caption)
          .foregroundStyle(.secondary)

        Spacer()

        Text(value.wrappedValue, format: .number.precision(.fractionLength(2)))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      PixelEditorStepSlider(
        value: value.wrappedValue,
        range: range,
        mode: mode,
        onChange: { newValue in
          value.wrappedValue = newValue
        }
      )
      .frame(height: 44)
    }
  }
}
#endif

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

private extension PixelEditorViewModel.Mode {

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

  var allowsCanvasInteraction: Bool {
    switch self {
    case .editing, .masking, .preview:
      return true
    case .crop:
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

}

private extension PixelEditorEditMenu {

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

  func title(localizedStrings: PixelEditorLocalizedStrings) -> String {
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

  var accessibilityIdentifier: String {
    switch self {
    case .adjustment:
      return "adjustment"
    case .mask:
      return "mask"
    case .exposure:
      return "exposure"
    case .gaussianBlur:
      return "gaussian-blur"
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
      return "clarity"
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
        || edit.localAdjustments.contains { $0.isEnabled && !$0.mask.isEmpty }
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

  func title(localizedStrings: PixelEditorLocalizedStrings) -> String {
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

  var accessibilityIdentifier: String {
    switch self {
    case .exposure:
      return "exposure"
    case .gaussianBlur:
      return "gaussian-blur"
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
      return "clarity"
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

  func displayValue(in filters: EditingStack.Edit.Filters?) -> Double {
    displayValue(forNativeValue: value(in: filters))
  }

  func setDisplayValue(_ value: Double, editingStack: EditingStack) {
    setValue(nativeValue(forDisplayValue: value), editingStack: editingStack)
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

  private func displayValue(forNativeValue value: Double) -> Double {
    guard value != 0 else {
      return 0
    }

    let nativeRange = range

    if value > 0 {
      guard nativeRange.upperBound != 0 else {
        return 0
      }
      return (value / nativeRange.upperBound * 100)
        .clamped(to: PixelEditorAdjustmentSliderMetrics.displayRange)
    } else {
      guard nativeRange.lowerBound != 0 else {
        return 0
      }
      return (value / abs(nativeRange.lowerBound) * 100)
        .clamped(to: PixelEditorAdjustmentSliderMetrics.displayRange)
    }
  }

  private func nativeValue(forDisplayValue value: Double) -> Double {
    let displayValue = value.clamped(to: PixelEditorAdjustmentSliderMetrics.displayRange)
    guard displayValue != 0 else {
      return 0
    }

    let nativeRange = range

    if displayValue > 0 {
      return nativeRange.upperBound * displayValue / 100
    } else {
      return abs(nativeRange.lowerBound) * displayValue / 100
    }
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

private extension Int {

  func clamped(to range: ClosedRange<Int>) -> Int {
    Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
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
