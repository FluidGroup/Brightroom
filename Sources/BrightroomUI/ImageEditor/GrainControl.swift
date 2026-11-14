// Copyright (c) 2026 Hiroshi Kimura (Muukii)

import BrightroomParametric
import SwiftUI

struct GrainControl: View {

  private let grain: GrainFeature.CameraRaw
  private let onChange: (GrainFeature.CameraRaw) -> Void
  private let onEnd: (GrainFeature.CameraRaw) -> Void

  // A Slider may retain its starting closure through the drag.
  @State private var pendingSliderValue: GrainFeature.CameraRaw?

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

    return HStack(spacing: 8) {
      Text(title)
        .frame(width: 72, alignment: .leading)

      Slider(
        value: Binding(
          get: { value },
          set: { value in
            var next = grain
            next[keyPath: axis] = value
            pendingSliderValue = next
            onChange(next)
          }
        ),
        in: 0...100,
        step: 1
      ) { editing in
        if !editing, let pendingSliderValue {
          onEnd(pendingSliderValue)
          self.pendingSliderValue = nil
        }
      }
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
