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
/// iPhone docks the feature pipeline in a bottom panel so the canvas stays
/// visible above it. iPad presents the same features as a leading sidebar. The
/// active feature determines both the row-local controls and the
/// `CropViewFeatureFocus` applied to the canvas.
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
      layout: horizontalSizeClass == .regular ? .sidebar : .compact,
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
    case compact
  }

  let model: ParametricFeatureEditorModel
  let layout: Layout
  let resetAction: SwiftUICropView.ResetAction
  let rotateAction: SwiftUICropView.RotateAction
  let applyAction: SwiftUICropView.ApplyAction
  let onSelectRow: (ParametricFeatureEditorRow) -> Void
  let onClose: (() -> Void)?

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
        .frame(width: 340)
        .background(Color(uiColor: .secondarySystemBackground))

        ParametricFeatureEditorCanvas(
          model: model,
          resetAction: resetAction,
          rotateAction: rotateAction,
          applyAction: applyAction
        )
      }

    case .compact:
      VStack(spacing: 0) {
        ParametricFeatureEditorCanvas(
          model: model,
          resetAction: resetAction,
          rotateAction: rotateAction,
          applyAction: applyAction
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(edges: .top)

        ParametricFeatureBottomPanel(
          model: model,
          resetAction: resetAction,
          rotateAction: rotateAction,
          onSelectRow: onSelectRow,
          onClose: onClose
        )
      }
    }
  }
}

/// The iPhone docked panel: a header, a horizontal feature pipeline, and the
/// active feature's controls. Docking keeps the canvas visible above it, and
/// the pipeline strip makes the stack order — and where a new feature lands —
/// explicit.
@available(iOS 17, *)
private struct ParametricFeatureBottomPanel: View {

  let model: ParametricFeatureEditorModel
  let resetAction: SwiftUICropView.ResetAction
  let rotateAction: SwiftUICropView.RotateAction
  let onSelectRow: (ParametricFeatureEditorRow) -> Void
  let onClose: (() -> Void)?

  var body: some View {
    VStack(spacing: 0) {
      ParametricFeatureListHeader(model: model, onClose: onClose, showsTitle: false)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)

      ParametricFeaturePipelineStrip(
        model: model,
        onSelectRow: onSelectRow
      )

      Divider()
        .overlay(Color.white.opacity(0.08))

      ParametricActiveFeatureControls(
        model: model,
        resetAction: resetAction,
        rotateAction: rotateAction
      )
      .frame(height: 142, alignment: .top)
      .padding(.horizontal, 16)
      .padding(.top, 12)
    }
    .background {
      // Only the background reaches the screen edge; the controls stay above
      // the home indicator.
      UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20)
        .fill(Color(uiColor: .secondarySystemBackground))
        .overlay(alignment: .top) {
          UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20)
            .stroke(Color.white.opacity(0.06), lineWidth: 1)
        }
        .ignoresSafeArea(edges: .bottom)
    }
  }
}

/// The horizontal feature pipeline: one chip per row in source-to-output order,
/// chevrons between them, the active one highlighted. Selecting a chip activates
/// that feature; adding a feature scrolls its new chip into view.
@available(iOS 17, *)
private struct ParametricFeaturePipelineStrip: View {

  let model: ParametricFeatureEditorModel
  let onSelectRow: (ParametricFeatureEditorRow) -> Void

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 4) {
          ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
            if index > 0 {
              Image(systemName: "chevron.compact.right")
                .font(.footnote)
                .foregroundStyle(.tertiary)
            }

            ParametricFeatureChip(
              row: row,
              isActive: row.id == model.selection.activeFeatureID,
              onSelect: { onSelectRow(row) }
            )
            .id(row.id)
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
      }
      .onChange(of: model.selection.activeFeatureID) { _, id in
        withAnimation(.easeInOut(duration: 0.25)) {
          proxy.scrollTo(id, anchor: .center)
        }
      }
    }
  }
}

@available(iOS 17, *)
private struct ParametricFeatureChip: View {

  let row: ParametricFeatureEditorRow
  let isActive: Bool
  let onSelect: () -> Void

  var body: some View {
    Button(action: onSelect) {
      VStack(spacing: 5) {
        Image(systemName: row.systemImageName)
          .font(.system(size: 18, weight: .semibold))
          .frame(height: 22)
        Text(row.title)
          .font(.system(size: 11, weight: .medium))
          .lineLimit(2)
          .multilineTextAlignment(.center)
          .minimumScaleFactor(0.8)
      }
      .frame(width: 68, height: 62)
      .padding(.horizontal, 2)
      .foregroundStyle(isActive ? Color.white : Color.secondary)
      .background(
        isActive ? Color.accentColor : Color.white.opacity(0.07),
        in: RoundedRectangle(cornerRadius: 14)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 14)
          .stroke(Color.white.opacity(isActive ? 0 : 0.08), lineWidth: 1)
      )
      .opacity(row.isEnabled ? 1 : 0.4)
    }
    .buttonStyle(.plain)
  }
}

/// The active feature's controls, shown in a fixed-height area so switching
/// features does not resize the panel.
@available(iOS 17, *)
private struct ParametricActiveFeatureControls: View {

  let model: ParametricFeatureEditorModel
  let resetAction: SwiftUICropView.ResetAction
  let rotateAction: SwiftUICropView.RotateAction

  var body: some View {
    Group {
      if let row = model.activeRow {
        ScrollView {
          ParametricFeatureRowControls(
            model: model,
            row: row,
            resetAction: resetAction,
            rotateAction: rotateAction
          )
          .padding(.bottom, 4)
        }
        .scrollIndicators(.hidden)
      } else {
        Text("Loading…")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .center)
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
    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
  var showsTitle: Bool = true

  var body: some View {
    HStack(spacing: 10) {
      if let onClose {
        Button("Done", action: onClose)
          .font(.headline)
          .accessibilityLabel("Close Editor")
      }

      if showsTitle {
        Text("Features")
          .font(.headline)
      }

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
