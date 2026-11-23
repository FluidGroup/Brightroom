#if os(macOS)
import BrightroomParametric
import SwiftUI

/// The macOS editor's inspector: a card for each adjustment section, and a
/// footer that resets them.
///
/// The column reads the displayed feature and hands each card its section's
/// members and state; cards read nothing from the model, so a drag
/// re-evaluates the column and the dragged card alone. The one exception is
/// White Balance's gray point, a row that reads the gray point's state in a
/// view of its own. Controls preview their values with
/// `ImageEditorModel.preview(_:in:)` and end each operation with
/// `commit(_:to:)`, or with `endOperation(_:in:)` when focus or the window
/// leaves a key step or a grading wheel's drag ends without its end.
struct AdjustmentInspector: View {

  /// The binding of the inspector's latest update. The controls' closures
  /// read it when they run, because a card whose inputs are unchanged keeps
  /// the closures of an earlier update, and the host may have bound another
  /// document of the same image since.
  private final class DocumentBinding {

    var current: Binding<ImageEditorDocument>

    init(_ current: Binding<ImageEditorDocument>) {
      self.current = current
    }
  }

  private let model: ImageEditorModel
  @Binding private var document: ImageEditorDocument
  @State private var documentBinding: DocumentBinding
  private let isLoaded: Bool
  private let localizedStrings: ImageEditor.LocalizedStrings

  /// The controls are disabled until `isLoaded`.
  init(
    model: ImageEditorModel,
    document: Binding<ImageEditorDocument>,
    isLoaded: Bool,
    localizedStrings: ImageEditor.LocalizedStrings
  ) {
    self.model = model
    self._document = document
    self._documentBinding = State(initialValue: DocumentBinding(document))
    self.isLoaded = isLoaded
    self.localizedStrings = localizedStrings
  }

  var body: some View {
    // Each update hands the controls' closures the current binding.
    let _ = documentBinding.current = $document

    VStack(spacing: 0) {
      // The layer picker's slot, empty while the editor has no layers.

      ScrollView {
        VStack(spacing: 8) {
          ForEach(ImageEditor.AdjustmentSection.allCases) { section in
            card(for: section)
          }
        }
        .padding(12)
      }

      Divider()

      // The Intensity slider's slot, empty while filters have no intensity.

      footer
    }
  }

  private func card(for section: ImageEditor.AdjustmentSection) -> some View {
    let members = section.members(of: model.shownFeature(for: section, in: document))
    let canReset = model.canReset(section, in: document)

    return AdjustmentCard(
      section: section,
      members: members,
      switchState: model.switchState(of: section, in: document),
      isExpanded: model.expandedSections.contains(section),
      canReset: canReset,
      isLoaded: isLoaded,
      localizedStrings: localizedStrings,
      onToggleExpanded: { model.toggleExpansion(of: section) },
      onSetSwitch: { model.setSection(section, isOn: $0, in: documentBinding.current) },
      onReset: { model.resetSection(section, in: documentBinding.current) }
    ) {
      content(of: section, members: members, canReset: canReset)
    } accessory: {
      EmptyView()
    }
    .equatable()
  }

  @ViewBuilder
  private func content(
    of section: ImageEditor.AdjustmentSection,
    members: ImageEditorFeature,
    canReset: Bool
  ) -> some View {
    switch section.content {
    case .adjustments(let rows):
      if section == .whiteBalance {
        GrayPointRow(model: model, isEnabled: isLoaded, hint: localizedStrings.grayPointHint)
      }

      ForEach(rows) { row in
        adjustmentRow(row, members: members)
      }
    case .colorGrading:
      ColorGradingCard(
        grading: members.effects.colorGrading ?? .init(),
        canReset: canReset,
        isLoaded: isLoaded,
        localizedStrings: localizedStrings,
        onChange: { model.preview(.colorGrading($0), in: documentBinding.current) },
        onEnd: { model.commit(.colorGrading($0), to: documentBinding.current) },
        onEndLater: { model.endOperation(.colorGrading, in: documentBinding.current) },
        onReset: { model.resetSection(.colorGrading, in: documentBinding.current) }
      )
    case .grain:
      grainRows(members.effects.grain ?? .init(amount: 0))
    }
  }

  @ViewBuilder
  private func adjustmentRow(
    _ row: ImageEditor.AdjustmentSection.Row,
    members: ImageEditorFeature
  ) -> some View {
    let parameter = row.parameter
    if let range = parameter.sliderRange {
      AdjustmentRow(
        title: row.title,
        value: parameter.sliderValue(in: members),
        range: range,
        neutralValue: 0,
        track: row.track,
        unit: row.unit,
        isEnabled: isLoaded,
        accessibilityIdentifier: parameter.accessibilityIdentifier,
        onChange: { model.preview(.slider(parameter, $0), in: documentBinding.current) },
        onEnd: { model.commit(.slider(parameter, $0), to: documentBinding.current) },
        onEndLater: { model.endOperation(.slider(parameter), in: documentBinding.current) }
      )
    }
  }

  private func grainRows(_ grain: GrainFeature.CameraRaw) -> some View {
    ForEach(ImageEditor.AdjustmentSection.grainAxes) { axis in
      AdjustmentRow(
        axis: axis,
        of: grain,
        // Size and roughness change nothing without an amount.
        isEnabled: isLoaded && (axis.keyPath == \.amount || grain.amount > 0),
        accessibilityIdentifier: "image-editor.grain.\(axis.id)",
        onChange: { model.preview(.grain($0), in: documentBinding.current) },
        onEnd: { model.commit(.grain($0), to: documentBinding.current) },
        onEndLater: { model.endOperation(.grain, in: documentBinding.current) }
      )
    }
  }

  private var footer: some View {
    HStack(spacing: 8) {
      Button {
        model.resetAdjustments(in: documentBinding.current)
      } label: {
        Text(localizedStrings.resetAdjustments)
          .frame(maxWidth: .infinity)
      }

      // The section names stand under a "Reset" header, so no string is
      // composed from a reset title and a section name.
      Menu {
        Section(localizedStrings.resetAdjustments) {
          ForEach(ImageEditor.AdjustmentSection.allCases) { section in
            Button(section.title) {
              model.resetSection(section, in: documentBinding.current)
            }
            .disabled(isLoaded == false || model.canReset(section, in: document) == false)
          }
        }
      } label: {
        Label(localizedStrings.resetSection, systemImage: "ellipsis.circle")
      }
      .labelStyle(.iconOnly)
      .menuStyle(.button)
      .buttonStyle(.borderless)
      .menuIndicator(.hidden)
      .fixedSize()
      .help(localizedStrings.resetSection)
    }
    // A section can be reset exactly when Reset has something to reset, so
    // the button and the menu are enabled together.
    .disabled(isLoaded == false || model.canResetAdjustments(in: document) == false)
    .padding(12)
  }
}

extension AdjustmentInspector {

  /// White Balance's gray point: an eyedropper that is on while the gray
  /// point is, when a click on the image sets the white balance that makes
  /// that area neutral.
  ///
  /// It reads the gray point's state itself, so it follows it although the
  /// card around it compares only its members.
  private struct GrayPointRow: View {

    /// Shown as written, not looked up in a strings table, as the other rows'
    /// titles are.
    private static let title = "Gray Point"

    let model: ImageEditorModel
    let isEnabled: Bool
    let hint: String

    var body: some View {
      let isSampling = model.grayPointSampling != .off

      HStack {
        Text(Self.title)
          .foregroundStyle(isEnabled ? .primary : .tertiary)
          .accessibilityHidden(true)

        Spacer()

        Toggle(isOn: Binding { isSampling } set: { setSampling($0) }) {
          Label(Self.title, systemImage: "eyedropper")
        }
        .toggleStyle(.button)
        .labelStyle(.iconOnly)
        .controlSize(.small)
        .help(hint)
        .accessibilityIdentifier("image-editor.adjust.grayPoint")
      }
      // A slider row below it starts with its title, so the gap keeps the
      // rows' rhythm.
      .padding(.bottom, 8)
      .disabled(isEnabled == false)
    }

    private func setSampling(_ isSampling: Bool) {
      if isSampling {
        model.beginGrayPointSampling()
      } else {
        model.cancelGrayPointSampling()
      }
    }
  }
}
#endif
