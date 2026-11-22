// Copyright (c) 2026 Hiroshi Kimura (Muukii)

#if os(iOS)
import BrightroomParametric
import SwiftUI
import UIKit

struct GrainControl: View {

  private let grain: GrainFeature.CameraRaw
  private let onChange: (GrainFeature.CameraRaw) -> Void
  private let onEnd: (GrainFeature.CameraRaw) -> Void

  init(
    grain: GrainFeature.CameraRaw,
    onChange: @escaping (GrainFeature.CameraRaw) -> Void,
    onEnd: @escaping (GrainFeature.CameraRaw) -> Void
  ) {
    self.grain = grain
    self.onChange = onChange
    self.onEnd = onEnd
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 8) {
        slider("Amount", axis: \.amount)
        slider("Size", axis: \.size)
        slider("Roughness", axis: \.roughness)

        HStack {
          Spacer()

          Button("Reset grain") {
            onEnd(.init(amount: 0))
          }
          .disabled(grain == .init(amount: 0))
          .accessibilityIdentifier("image-editor.grain.reset")
        }
        .font(.caption)
      }
      .padding(.vertical, 4)
    }
    .scrollIndicators(.hidden)
    .tint(.white)
    .accessibilityIdentifier("image-editor.grain")
  }

  private func slider(
    _ title: String,
    axis: WritableKeyPath<GrainFeature.CameraRaw, Double>
  ) -> some View {
    let value = grain[keyPath: axis]
    let resetValue = GrainFeature.CameraRaw(amount: 0)[keyPath: axis]

    return HStack(spacing: 8) {
      Text(title)
        .frame(width: 72, alignment: .leading)

      SteppedSlider(
        value: Binding(
          get: { value },
          set: { newValue in
            let rounded = newValue.rounded()
            guard rounded != value else {
              return
            }

            var next = grain
            next[keyPath: axis] = rounded
            onChange(next)
          }
        ),
        range: 0...100,
        stepCount: 100,
        style: .imageEditorAdjustmentSlider,
        resetValue: resetValue,
        snapsToTicksOnEditingEnd: false,
        transform: { $0.rounded() },
        hapticIdentity: { value in
          let step = Int(value.rounded())
          return step.isMultiple(of: 25) ? AnyHashable(step) : nil
        },
        onHaptic: {
          UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.35)
        },
        onEditingEnded: { value in
          var next = grain
          next[keyPath: axis] = value.rounded()
          onEnd(next)
        },
        topMarker: { context in
          Circle()
            .frame(width: 6, height: 6)
            .opacity(context.value == resetValue && value != resetValue ? 1 : 0)
            .animation(.spring, value: value == resetValue)
        },
        tick: { context in
          Capsule()
            .foregroundStyle(context.isMajor ? Color.primary : Color.secondary)
        }
      )
      .frame(height: 44)
      .accessibilityLabel(title)
      .accessibilityValue("\(Int(value.rounded()))")
      .accessibilityIdentifier("image-editor.grain.\(title.lowercased())")

      Text(value, format: .number.precision(.fractionLength(0)))
        .monospacedDigit()
        .frame(width: 28, alignment: .trailing)
        .accessibilityHidden(true)
    }
    .font(.caption)
  }

}

#Preview {
  @Previewable @State var grain = GrainFeature.CameraRaw(amount: 20, size: 42, roughness: 70)

  GrainControl(grain: grain, onChange: { grain = $0 }, onEnd: { grain = $0 })
    .padding(24)
    .frame(height: 180)
    .preferredColorScheme(.dark)
}
#endif
