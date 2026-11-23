#if os(macOS)
import BrightroomParametric
import SwiftUI

/// The Color Grading card's content: a picker between two layouts of the
/// grading wheels, a button that resets the section, and the layout.
///
/// 3-Way shows a wheel and a luminance slider for each of shadows, midtones
/// and highlights, then Blending and Balance; Global shows one wheel for the
/// whole image and its luminance. The picker chooses only what shows: both
/// layouts edit the same grading. A wheel takes a pointer and, through Full
/// Keyboard Access, the arrow keys (`ColorGradingWheel.Interaction.pointer`),
/// and a double-click on it or its context menu resets its range.
struct ColorGradingCard: View {

  enum Mode: Hashable {
    case threeWay
    case global
  }

  private static let threeWayRanges: [ColorGradingFeature.Range] = [.shadows, .midtones, .highlights]
  private static let luminanceRange: ClosedRange<Double> = -100...100

  private let grading: ColorGradingFeature
  private let canReset: Bool
  private let isLoaded: Bool
  private let localizedStrings: ImageEditor.LocalizedStrings
  private let onChange: (ColorGradingFeature) -> Void
  private let onEnd: (ColorGradingFeature) -> Void
  private let onEndLater: () -> Void
  private let onReset: () -> Void

  @State private var mode: Mode

  /// The callbacks follow `AdjustmentSlider`'s: `onChange` previews a
  /// grading in progress, `onEnd` ends an operation with its grading, and
  /// `onEndLater` ends a key step that focus or the window left, or a wheel's
  /// drag that ended without its end. `onReset` resets the section.
  init(
    grading: ColorGradingFeature,
    canReset: Bool,
    isLoaded: Bool,
    localizedStrings: ImageEditor.LocalizedStrings,
    onChange: @escaping (ColorGradingFeature) -> Void,
    onEnd: @escaping (ColorGradingFeature) -> Void,
    onEndLater: @escaping () -> Void,
    onReset: @escaping () -> Void
  ) {
    self.grading = grading
    self.canReset = canReset
    self.isLoaded = isLoaded
    self.localizedStrings = localizedStrings
    self.onChange = onChange
    self.onEnd = onEnd
    self.onEndLater = onEndLater
    self.onReset = onReset
    self._mode = State(initialValue: Self.initialMode(for: grading))
  }

  /// Global when only the global correction is set; otherwise 3-Way.
  static func initialMode(for grading: ColorGradingFeature) -> Mode {
    var ranges = grading
    ranges.global = .init()
    if grading.global != .init(), ranges == .init() {
      return .global
    }
    return .threeWay
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        modePicker

        Button(action: onReset) {
          // A borderless button is otherwise only as large as its glyph.
          Label(localizedStrings.resetAdjustments, systemImage: "arrow.counterclockwise")
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help(localizedStrings.resetAdjustments)
        .disabled(canReset == false || isLoaded == false)
      }

      switch mode {
      case .threeWay:
        threeWay
      case .global:
        global
      }
    }
  }

  /// Full width. From macOS 26 a pop-up button keeps to its content's width
  /// unless its sizing is flexible.
  @ViewBuilder
  private var modePicker: some View {
    let picker = Picker(ImageEditor.AdjustmentSection.colorGrading.title, selection: $mode) {
      Text(localizedStrings.colorGradingThreeWay)
        .tag(Mode.threeWay)
      Text(localizedStrings.colorGradingGlobal)
        .tag(Mode.global)
    }
    .pickerStyle(.menu)
    .labelsHidden()

    if #available(macOS 26, *) {
      picker
        .buttonSizing(.flexible)
        .frame(maxWidth: .infinity)
    } else {
      picker
        .frame(maxWidth: .infinity)
    }
  }

  private var threeWay: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .top, spacing: 8) {
        ForEach(Self.threeWayRanges) { range in
          VStack(spacing: 4) {
            wheel(for: range)
              .aspectRatio(1, contentMode: .fit)

            Text(Self.title(of: range))
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)

            AdjustmentSlider(
              value: grading[range].luminance,
              range: Self.luminanceRange,
              neutralValue: 0,
              track: .plain,
              isEnabled: isLoaded,
              accessibilityLabel: "\(Self.title(of: range)) Luminance",
              accessibilityIdentifier: "image-editor.grading.\(range.rawValue).luminance",
              valueDescription: ImageEditor.AdjustmentSection.Unit.percent.text(for:),
              onChange: { onChange(changing(luminanceOf: range, to: $0)) },
              onEnd: { onEnd(changing(luminanceOf: range, to: $0)) },
              onEndLater: onEndLater
            )
            .controlSize(.mini)
            .frame(height: 20)
            // As in `AdjustmentRow`: SwiftUI also sets the slider's enabled
            // state from the environment.
            .disabled(isLoaded == false)
          }
          .frame(maxWidth: .infinity)
        }
      }

      ForEach(ImageEditor.AdjustmentSection.gradingAxes) { axis in
        AdjustmentRow(
          axis: axis,
          of: grading,
          isEnabled: isLoaded,
          accessibilityIdentifier: "image-editor.grading.\(axis.id)",
          onChange: onChange,
          onEnd: onEnd,
          onEndLater: onEndLater
        )
      }
    }
  }

  private var global: some View {
    VStack(alignment: .leading, spacing: 8) {
      wheel(for: .global)
        .frame(width: 120, height: 120)
        .frame(maxWidth: .infinity)

      AdjustmentRow(
        title: "Luminance",
        value: grading.global.luminance,
        range: Self.luminanceRange,
        neutralValue: 0,
        track: .plain,
        unit: .percent,
        isEnabled: isLoaded,
        accessibilityIdentifier: "image-editor.grading.global.luminance",
        onChange: { onChange(changing(luminanceOf: .global, to: $0)) },
        onEnd: { onEnd(changing(luminanceOf: .global, to: $0)) },
        onEndLater: onEndLater
      )
    }
  }

  private func wheel(for range: ColorGradingFeature.Range) -> some View {
    ColorGradingWheel(
      correction: grading[range],
      rangeName: Self.title(of: range),
      interaction: .pointer,
      onChange: { onChange(changing(range, to: $0)) },
      onEnd: { onEnd(changing(range, to: $0)) },
      onEndLater: onEndLater
    )
    .disabled(isLoaded == false)
    .contextMenu {
      Button(localizedStrings.resetAdjustments) {
        onEnd(changing(range, to: .init()))
      }
      .disabled(grading[range] == .init() || isLoaded == false)
    }
  }

  /// The grading with `range`'s correction replaced.
  private func changing(
    _ range: ColorGradingFeature.Range,
    to correction: ColorGradingFeature.Correction
  ) -> ColorGradingFeature {
    var next = grading
    next[range] = correction
    return next
  }

  private func changing(
    luminanceOf range: ColorGradingFeature.Range,
    to luminance: Double
  ) -> ColorGradingFeature {
    var next = grading
    next[range].luminance = luminance
    return next
  }

  /// The range's name, as iOS's grading control shows it.
  private static func title(of range: ColorGradingFeature.Range) -> String {
    range.rawValue.capitalized
  }
}
#endif
