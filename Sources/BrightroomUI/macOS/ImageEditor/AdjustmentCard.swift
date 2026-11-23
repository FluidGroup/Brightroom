#if os(macOS)
import SwiftUI

/// A section of the macOS inspector: a card whose header expands and
/// collapses it and holds the section's switch, with a context menu that
/// resets the section.
///
/// The card is equatable over its inputs, closures aside, and the inspector
/// uses it with `.equatable()`, so a drag in one card leaves the other cards'
/// bodies alone. A card whose inputs are unchanged keeps its body, closures
/// included, from an earlier update, so its content shows nothing but those
/// inputs, `members` above all, and what a view of its own reads from the
/// model. Of the localized strings it compares its own; the content's
/// strings update with the card's next change.
struct AdjustmentCard<Content: View, Accessory: View>: View, Equatable {

  private let section: ImageEditor.AdjustmentSection
  /// The section's members (`AdjustmentSection.members(of:)`): the values
  /// the content shows.
  private let members: ImageEditorFeature
  /// nil hides the switch: the section has nothing to switch.
  private let switchState: ImageEditor.AdjustmentSection.SwitchState?
  private let isExpanded: Bool
  private let canReset: Bool
  private let isLoaded: Bool
  private let resetTitle: String
  private let expandedValue: String
  private let collapsedValue: String
  private let onToggleExpanded: () -> Void
  private let onSetSwitch: (Bool) -> Void
  private let onReset: () -> Void
  private let content: Content
  private let accessory: Accessory

  @State private var isHovering = false
  @FocusState private var isHeaderFocused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// `accessory` sits in the header, before the switch.
  init(
    section: ImageEditor.AdjustmentSection,
    members: ImageEditorFeature,
    switchState: ImageEditor.AdjustmentSection.SwitchState?,
    isExpanded: Bool,
    canReset: Bool,
    isLoaded: Bool,
    localizedStrings: ImageEditor.LocalizedStrings,
    onToggleExpanded: @escaping () -> Void,
    onSetSwitch: @escaping (Bool) -> Void,
    onReset: @escaping () -> Void,
    @ViewBuilder content: () -> Content,
    @ViewBuilder accessory: () -> Accessory
  ) {
    self.section = section
    self.members = members
    self.switchState = switchState
    self.isExpanded = isExpanded
    self.canReset = canReset
    self.isLoaded = isLoaded
    self.resetTitle = localizedStrings.resetAdjustments
    self.expandedValue = localizedStrings.expanded
    self.collapsedValue = localizedStrings.collapsed
    self.onToggleExpanded = onToggleExpanded
    self.onSetSwitch = onSetSwitch
    self.onReset = onReset
    self.content = content()
    self.accessory = accessory()
  }

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.section == rhs.section
      && lhs.members == rhs.members
      && lhs.switchState == rhs.switchState
      && lhs.isExpanded == rhs.isExpanded
      && lhs.canReset == rhs.canReset
      && lhs.isLoaded == rhs.isLoaded
      && lhs.resetTitle == rhs.resetTitle
      && lhs.expandedValue == rhs.expandedValue
      && lhs.collapsedValue == rhs.collapsedValue
  }

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 8) {
        header

        if isExpanded {
          VStack(alignment: .leading, spacing: 4) {
            content
          }
          // 13 points from the card's bottom, with the group box's 5.
          .padding(.bottom, 8)
          // A switched-off section shows the values it keeps; editing one
          // switches the section back on.
          .opacity(switchState == .off ? 0.55 : 1)
        }
      }
      // 13 points from the card's sides, with the group box's 5.
      .padding(.horizontal, 8)
    }
    .contextMenu {
      Button(resetTitle, action: onReset)
        .disabled(canReset == false || isLoaded == false)
    }
    // VoiceOver names the card by its section, so rows that share a title,
    // such as Vignette's and Grain's Amount, read apart.
    .accessibilityElement(children: .contain)
    .accessibilityLabel(section.title)
    .accessibilityIdentifier(section.accessibilityIdentifier)
  }

  private var header: some View {
    HStack(spacing: 8) {
      Button {
        withAnimation(expansionAnimation) {
          onToggleExpanded()
        }
      } label: {
        HStack(spacing: 4) {
          Text(section.title)
            .font(.headline)

          // Shown while the pointer is over the header or the keyboard is
          // on its button.
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .opacity(isHovering || isHeaderFocused ? 1 : 0)
            .accessibilityHidden(true)

          Spacer(minLength: 0)
        }
        // The header's full height is the target.
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .focused($isHeaderFocused)
      .accessibilityAddTraits(.isHeader)
      .accessibilityValue(isExpanded ? expandedValue : collapsedValue)

      accessory

      if switchState != nil {
        Toggle(section.title, isOn: switchBinding)
          .toggleStyle(.switch)
          .controlSize(.mini)
          .labelsHidden()
          .disabled(isLoaded == false)
      }
    }
    .frame(height: 24)
    .onHover { isHovering = $0 }
  }

  /// On while the section has values. Switching it on expands the card, so
  /// the switch animates as the header does.
  private var switchBinding: Binding<Bool> {
    Binding {
      switchState == .on
    } set: { isOn in
      withAnimation(expansionAnimation) {
        onSetSwitch(isOn)
      }
    }
  }

  /// None under Reduce Motion.
  private var expansionAnimation: Animation? {
    reduceMotion ? nil : .snappy(duration: 0.2)
  }
}

/// A slider of the inspector: its title and value over an `AdjustmentSlider`.
/// VoiceOver reads the slider alone, labelled with the title.
struct AdjustmentRow: View {

  private let title: String
  private let value: Double
  private let range: ClosedRange<Double>
  private let neutralValue: Double
  private let track: ImageEditor.AdjustmentSection.Track
  private let unit: ImageEditor.AdjustmentSection.Unit
  private let isEnabled: Bool
  private let accessibilityIdentifier: String
  private let onChange: (Double) -> Void
  private let onEnd: (Double) -> Void
  private let onEndLater: () -> Void

  /// The callbacks are the slider's: `onChange` previews a value in
  /// progress, `onEnd` ends an operation with its value, and `onEndLater`
  /// ends a key step that focus or the window left.
  init(
    title: String,
    value: Double,
    range: ClosedRange<Double>,
    neutralValue: Double,
    track: ImageEditor.AdjustmentSection.Track,
    unit: ImageEditor.AdjustmentSection.Unit,
    isEnabled: Bool,
    accessibilityIdentifier: String,
    onChange: @escaping (Double) -> Void,
    onEnd: @escaping (Double) -> Void,
    onEndLater: @escaping () -> Void
  ) {
    self.title = title
    self.value = value
    self.range = range
    self.neutralValue = neutralValue
    self.track = track
    self.unit = unit
    self.isEnabled = isEnabled
    self.accessibilityIdentifier = accessibilityIdentifier
    self.onChange = onChange
    self.onEnd = onEnd
    self.onEndLater = onEndLater
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Dimmed with a disabled slider, as a system slider's label is.
      HStack {
        Text(title)
          .foregroundStyle(isEnabled ? .primary : .tertiary)

        Spacer()

        Text(unit.text(for: value))
          .monospacedDigit()
          .foregroundStyle(isEnabled ? .secondary : .tertiary)
      }
      .accessibilityHidden(true)

      AdjustmentSlider(
        value: value,
        range: range,
        neutralValue: neutralValue,
        track: track,
        isEnabled: isEnabled,
        accessibilityLabel: title,
        accessibilityIdentifier: accessibilityIdentifier,
        valueDescription: unit.text(for:),
        onChange: onChange,
        onEnd: onEnd,
        onEndLater: onEndLater
      )
      .controlSize(.mini)
      .frame(height: 20)
    }
    // SwiftUI also sets a hosted control's enabled state from the
    // environment, which would otherwise enable a disabled slider.
    .disabled(isEnabled == false)
  }
}

extension AdjustmentRow {

  /// A row for `axis` of `base`. Its callbacks receive `base` with the axis
  /// set to the slider's value.
  init<Value>(
    axis: ImageEditor.AdjustmentSection.Axis<Value>,
    of base: Value,
    isEnabled: Bool,
    accessibilityIdentifier: String,
    onChange: @escaping (Value) -> Void,
    onEnd: @escaping (Value) -> Void,
    onEndLater: @escaping () -> Void
  ) {
    func setting(_ value: Double) -> Value {
      var next = base
      next[keyPath: axis.keyPath] = value
      return next
    }

    self.init(
      title: axis.title,
      value: base[keyPath: axis.keyPath],
      range: axis.range,
      neutralValue: axis.neutralValue,
      track: axis.track,
      unit: axis.unit,
      isEnabled: isEnabled,
      accessibilityIdentifier: accessibilityIdentifier,
      onChange: { onChange(setting($0)) },
      onEnd: { onEnd(setting($0)) },
      onEndLater: onEndLater
    )
  }
}

extension ImageEditor.AdjustmentSection.Unit {

  /// A value as the inspector shows it, in whole numbers: "12%" or "12".
  /// VoiceOver reads the same text ("12 percent").
  func text(for value: Double) -> String {
    var whole = value.rounded()
    if whole == 0 {
      // A value just under zero rounds to -0, which reads "-0".
      whole = 0
    }

    switch self {
    case .percent:
      return (whole / 100).formatted(.percent.precision(.fractionLength(0)))
    case .number:
      return whole.formatted(.number.precision(.fractionLength(0)))
    }
  }
}
#endif
