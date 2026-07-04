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

#if os(iOS)

import Observation
import SwiftUI

import BrightroomEngine
import BrightroomParametric

/// A SwiftUI parametric editor that pairs one CropView canvas with a feature
/// list.
///
/// iPhone presents the list as a bottom sheet-like panel. iPad presents the
/// same list as a leading sidebar. The active feature row determines both the
/// row-local controls and the `CropViewFeatureFocus` applied to the canvas.
@available(iOS 17, *)
public struct SwiftUIParametricFeatureEditorView: View {

  private let model: ParametricFeatureEditorModel
  private let onClose: (() -> Void)?

  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  @State private var resetAction = SwiftUICropView.ResetAction()
  @State private var rotateAction = SwiftUICropView.RotateAction()
  @State private var applyAction = SwiftUICropView.ApplyAction()

  /// Creates the editor.
  ///
  /// - Parameters:
  ///   - model: The policy layer over the editing stack.
  ///   - onClose: Called when the user taps the feature list's Done control.
  ///     Pass nil for hosts that supply their own dismissal chrome; the Done
  ///     control is then hidden.
  public init(
    model: ParametricFeatureEditorModel,
    onClose: (() -> Void)? = nil
  ) {
    self.model = model
    self.onClose = onClose
  }

  public var body: some View {
    ParametricFeatureEditorRoot(
      model: model,
      layout: horizontalSizeClass == .regular ? .sidebar : .bottomSheet,
      resetAction: resetAction,
      rotateAction: rotateAction,
      applyAction: applyAction,
      onSelectRow: selectRow(_:),
      onClose: onClose.map { close in
        {
          if model.selection.mode == .crop {
            applyAction()
          }
          model.commitCurrentEditIfNeeded()
          close()
        }
      }
    )
    .background(Color.black)
    .task {
      model.start()
    }
  }

  private func selectRow(_ row: ParametricFeatureEditorRow) {
    if model.selection.mode == .crop {
      applyAction()
    }
    model.commitCurrentEditIfNeeded()
    model.select(row: row)
  }
}

@available(iOS 17, *)
private struct ParametricFeatureEditorRoot: View {

  enum Layout {
    case sidebar
    case bottomSheet
  }

  let model: ParametricFeatureEditorModel
  let layout: Layout
  let resetAction: SwiftUICropView.ResetAction
  let rotateAction: SwiftUICropView.RotateAction
  let applyAction: SwiftUICropView.ApplyAction
  let onSelectRow: (ParametricFeatureEditorRow) -> Void
  let onClose: (() -> Void)?

  @State private var isCompactFeatureSheetPresented = true
  @State private var compactFeatureSheetDetent = PresentationDetent.height(320)

  var body: some View {
    switch layout {
    case .sidebar:
      HStack(spacing: 0) {
        ParametricFeatureListPanel(
          model: model,
          resetAction: resetAction,
          rotateAction: rotateAction,
          onSelectRow: onSelectRow,
          onClose: onClose
        )
        .frame(width: 360)
        .background(Color(uiColor: .secondarySystemBackground))

        ParametricFeatureEditorCanvas(
          model: model,
          resetAction: resetAction,
          rotateAction: rotateAction,
          applyAction: applyAction
        )
      }

    case .bottomSheet:
      ParametricFeatureEditorCanvas(
        model: model,
        resetAction: resetAction,
        rotateAction: rotateAction,
        applyAction: applyAction
      )
      .sheet(isPresented: $isCompactFeatureSheetPresented) {
        ParametricFeatureListPanel(
          model: model,
          resetAction: resetAction,
          rotateAction: rotateAction,
          onSelectRow: onSelectRow,
          onClose: onClose
        )
        .presentationDetents(
          [.height(320), .medium, .large],
          selection: $compactFeatureSheetDetent
        )
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .interactiveDismissDisabled()
      }
      .onAppear {
        isCompactFeatureSheetPresented = true
      }
    }
  }
}

@available(iOS 17, *)
private struct ParametricFeatureEditorCanvas: View {

  let model: ParametricFeatureEditorModel
  let resetAction: SwiftUICropView.ResetAction
  let rotateAction: SwiftUICropView.RotateAction
  let applyAction: SwiftUICropView.ApplyAction

  var body: some View {
    let focus = model.currentFeatureFocus

    ZStack(alignment: .topLeading) {
      SwiftUICropView(
        document: model.cropViewDocument,
        isGuideInteractionEnabled: focus.isCropEditing
      )
      .featureFocus(focus)
      .maskingBrush(model.maskingBrush)
      .registerResetAction(resetAction)
      .registerRotateAction(rotateAction)
      .registerApplyAction(applyAction)
      .background(Color.black)

      if let row = model.activeRow {
        ParametricFeatureCanvasBadge(row: row, mode: model.selection.mode)
          .padding(12)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

@available(iOS 17, *)
private struct ParametricFeatureCanvasBadge: View {

  let row: ParametricFeatureEditorRow
  let mode: ParametricFeatureEditorSelection.Mode

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: row.systemImageName)
        .font(.footnote.weight(.semibold))
      Text(row.title)
        .font(.footnote.weight(.semibold))
      Text(mode.title)
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .foregroundStyle(.white)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
  }
}

@available(iOS 17, *)
private struct ParametricFeatureListPanel: View {

  let model: ParametricFeatureEditorModel
  let resetAction: SwiftUICropView.ResetAction
  let rotateAction: SwiftUICropView.RotateAction
  let onSelectRow: (ParametricFeatureEditorRow) -> Void
  let onClose: (() -> Void)?

  var body: some View {
    VStack(spacing: 0) {
      ParametricFeatureListHeader(model: model, onClose: onClose)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)

      Divider()

      ScrollView {
        LazyVStack(spacing: 8) {
          ForEach(model.rows) { row in
            ParametricFeatureRowView(
              model: model,
              row: row,
              isActive: row.id == model.selection.activeFeatureID,
              resetAction: resetAction,
              rotateAction: rotateAction,
              onSelect: {
                onSelectRow(row)
              }
            )
          }
        }
        .padding(10)
      }
      .scrollIndicators(.hidden)
    }
  }
}

@available(iOS 17, *)
private struct ParametricFeatureListHeader: View {

  let model: ParametricFeatureEditorModel
  let onClose: (() -> Void)?

  var body: some View {
    HStack(spacing: 10) {
      if let onClose {
        Button("Done", action: onClose)
          .font(.headline)
          .accessibilityLabel("Close Editor")
      }

      Text("Features")
        .font(.headline)

      Spacer()

      Button {
        model.commitCurrentEditIfNeeded()
        model.editingStack.undo()
      } label: {
        Image(systemName: "arrow.uturn.backward")
      }
      .disabled(model.loadedState?.canUndo != true)
      .accessibilityLabel("Undo")

      Button {
        model.commitCurrentEditIfNeeded()
        model.editingStack.redo()
      } label: {
        Image(systemName: "arrow.uturn.forward")
      }
      .disabled(model.loadedState?.canRedo != true)
      .accessibilityLabel("Redo")

      Menu {
        ForEach(ParametricFeatureEditorAdjustmentParameter.allCases) { parameter in
          Button {
            model.addGlobalAdjustment(parameter)
          } label: {
            Label(parameter.title, systemImage: parameter.systemImageName)
          }
        }

        Divider()

        Button {
          model.addCrop()
        } label: {
          Label("Crop", systemImage: "crop")
        }

        Button {
          model.addBlurMaskAdjustment()
        } label: {
          Label("Blur Mask", systemImage: "paintbrush.pointed")
        }
      } label: {
        Image(systemName: "plus")
      }
      .accessibilityLabel("Add Feature")
    }
    .buttonStyle(.borderless)
  }
}

@available(iOS 17, *)
private struct ParametricFeatureRowView: View {

  let model: ParametricFeatureEditorModel
  let row: ParametricFeatureEditorRow
  let isActive: Bool
  let resetAction: SwiftUICropView.ResetAction
  let rotateAction: SwiftUICropView.RotateAction
  let onSelect: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Button(action: onSelect) {
        ParametricFeatureRowHeader(row: row, isActive: isActive)
      }
      .buttonStyle(.plain)

      if isActive {
        ParametricFeatureRowControls(
          model: model,
          row: row,
          resetAction: resetAction,
          rotateAction: rotateAction
        )
      }
    }
    .padding(10)
    .padding(.leading, CGFloat(row.indentationLevel) * 18)
    .background(
      isActive
        ? Color.accentColor.opacity(0.18)
        : Color(uiColor: .tertiarySystemFill),
      in: RoundedRectangle(cornerRadius: 8)
    )
    .opacity(row.isEnabled ? 1 : 0.55)
  }
}

@available(iOS 17, *)
private struct ParametricFeatureRowHeader: View {

  let row: ParametricFeatureEditorRow
  let isActive: Bool

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: row.systemImageName)
        .font(.body.weight(.semibold))
        .frame(width: 24, height: 24)
        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)

      VStack(alignment: .leading, spacing: 2) {
        Text(row.title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.primary)
        Text(row.subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 8)

      if isActive {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(Color.accentColor)
      }
    }
    .contentShape(Rectangle())
  }
}

@available(iOS 17, *)
private struct ParametricFeatureRowControls: View {

  let model: ParametricFeatureEditorModel
  let row: ParametricFeatureEditorRow
  let resetAction: SwiftUICropView.ResetAction
  let rotateAction: SwiftUICropView.RotateAction

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      switch row.kind {
      case .source, .output, .unsupported:
        ParametricFeatureModePicker(
          model: model,
          modes: [.preview]
        )

      case .globalEffects:
        ParametricFeatureModePicker(
          model: model,
          modes: [.parameters, .preview]
        )
        ParametricGlobalEffectsAddStrip(model: model)

      case let .globalAdjustment(parameter):
        ParametricFeatureModePicker(
          model: model,
          modes: [.parameters, .preview]
        )
        ParametricGlobalAdjustmentSlider(
          model: model,
          parameter: parameter
        )
        ParametricFeatureDeleteButton {
          model.removeGlobalAdjustment(parameter)
        }

      case .localAdjustment:
        ParametricFeatureModePicker(
          model: model,
          modes: [.mask, .parameters, .preview]
        )
        ParametricLocalAdjustmentControls(model: model, rowID: row.id)
        ParametricFeatureDeleteButton {
          model.removeFeature(id: row.id)
        }

      case .crop:
        ParametricFeatureModePicker(
          model: model,
          modes: [.crop, .preview]
        )
        ParametricCropControls(
          resetAction: resetAction,
          rotateAction: rotateAction
        )
        ParametricFeatureDeleteButton {
          model.removeFeature(id: row.id)
        }

      case .finalCrop:
        ParametricFeatureModePicker(
          model: model,
          modes: [.crop, .preview]
        )
        ParametricCropControls(
          resetAction: resetAction,
          rotateAction: rotateAction
        )
      }
    }
  }
}

@available(iOS 17, *)
private struct ParametricFeatureModePicker: View {

  let model: ParametricFeatureEditorModel
  let modes: [ParametricFeatureEditorSelection.Mode]

  var body: some View {
    @Bindable var model = model

    Picker("Mode", selection: $model.selection.mode) {
      ForEach(modes, id: \.self) { mode in
        Label(mode.title, systemImage: mode.systemImageName)
          .tag(mode)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
  }
}

@available(iOS 17, *)
private struct ParametricGlobalEffectsAddStrip: View {

  let model: ParametricFeatureEditorModel

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(ParametricFeatureEditorAdjustmentParameter.allCases) { parameter in
          Button {
            model.addGlobalAdjustment(parameter)
          } label: {
            Label(parameter.title, systemImage: parameter.systemImageName)
              .labelStyle(.iconOnly)
              .frame(width: 34, height: 30)
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .accessibilityLabel(parameter.title)
        }
      }
    }
    .scrollIndicators(.hidden)
  }
}

@available(iOS 17, *)
private struct ParametricGlobalAdjustmentSlider: View {

  let model: ParametricFeatureEditorModel
  let parameter: ParametricFeatureEditorAdjustmentParameter

  var body: some View {
    @Bindable var model = model

    ParametricSliderRow(
      title: parameter.title,
      value: $model[globalAdjustment: parameter],
      range: parameter.sliderRange
    )
  }
}

@available(iOS 17, *)
private struct ParametricLocalAdjustmentControls: View {

  let model: ParametricFeatureEditorModel
  let rowID: FeatureID

  var body: some View {
    @Bindable var model = model

    VStack(spacing: 10) {
      ParametricSliderRow(
        title: "Blur",
        value: $model[localAdjustmentBlur: rowID],
        range: ParametricFeatureEditorAdjustmentParameter.blur.sliderRange
      )

      ParametricSliderRow(
        title: "Brush",
        value: $model.maskBrushPointDiameter,
        range: 12...120
      )
    }
  }
}

@available(iOS 17, *)
private struct ParametricCropControls: View {

  let resetAction: SwiftUICropView.ResetAction
  let rotateAction: SwiftUICropView.RotateAction

  var body: some View {
    HStack(spacing: 10) {
      Button {
        rotateAction()
      } label: {
        Label("Rotate", systemImage: "rotate.right")
      }
      .buttonStyle(.bordered)

      Button {
        resetAction()
      } label: {
        Label("Reset", systemImage: "arrow.counterclockwise")
      }
      .buttonStyle(.bordered)
    }
    .controlSize(.small)
  }
}

@available(iOS 17, *)
private struct ParametricSliderRow: View {

  let title: String
  @Binding var value: Double
  let range: ClosedRange<Double>

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(title)
          .font(.caption.weight(.semibold))
        Spacer()
        Text("\(Int(value.rounded()))")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      Slider(value: $value, in: range)
    }
  }
}

@available(iOS 17, *)
private struct ParametricFeatureDeleteButton: View {

  let action: () -> Void

  var body: some View {
    Button(role: .destructive, action: action) {
      Label("Delete", systemImage: "trash")
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
  }
}

private extension ParametricFeatureEditorSelection.Mode {

  var title: String {
    switch self {
    case .preview: return "Preview"
    case .crop: return "Crop"
    case .mask: return "Mask"
    case .parameters: return "Edit"
    }
  }

  var systemImageName: String {
    switch self {
    case .preview: return "eye"
    case .crop: return "crop"
    case .mask: return "paintbrush.pointed"
    case .parameters: return "slider.horizontal.3"
    }
  }
}

#endif
