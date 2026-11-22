// Copyright (c) 2026 Hiroshi Kimura (Muukii)

import BrightroomParametric
import SwiftUI

/// A grading wheel and exact-value sliders sharing one live preview operation.
/// The editor owns the value and commits only `onEnd` to its document.
struct ColorGradingControl: View {

  let grading: ColorGradingFeature
  let onChange: (ColorGradingFeature) -> Void
  let onEnd: (ColorGradingFeature) -> Void

  @State private var selection: ColorGradingFeature.Range = .midtones
  // SwiftUI may retain the slider's starting onEditingChanged closure for a
  // whole gesture. Commit the last emitted value, not that closure's snapshot.
  @State private var pendingSliderValue: ColorGradingFeature?

  var body: some View {
    ScrollView {
      VStack(spacing: 8) {
        Picker("Tonal range", selection: $selection) {
          ForEach(ColorGradingFeature.Range.allCases) { range in
            Text(range.rawValue.capitalized).tag(range)
          }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("image-editor.grading.range")

        HStack(spacing: 16) {
          wheel
            .frame(width: 112, height: 112)
          VStack(spacing: 4) {
            correctionSlider("Hue", axis: \.hue, range: 0...360)
            correctionSlider("Saturation", axis: \.saturation, range: 0...100)
            correctionSlider("Luminance", axis: \.luminance, range: -100...100)
          }
        }
        .padding(.vertical, 4)

        if selection != .global {
          gradingSlider("Blending", axis: \.blending, range: 0...100)
          gradingSlider("Balance", axis: \.balance, range: -100...100)
        }

        HStack {
          Button("Reset range") {
            var next = grading
            next[selection] = .init()
            onEnd(next)
          }
          .disabled(grading[selection] == .init())
          Spacer()
          Button("Reset grading") { onEnd(.init()) }
            .disabled(grading == .init())
        }
        .font(.caption)
      }
      .padding(.vertical, 4)
    }
    .scrollIndicators(.hidden)
    .tint(.white)
    .accessibilityIdentifier("image-editor.grading")
  }

  /// The wheel is a two-axis shortcut; the adjacent sliders provide the same
  /// values through VoiceOver, keyboard adjustment, and precise single-axis edits.
  private var wheel: some View {
    GeometryReader { geometry in
      let radius = min(geometry.size.width, geometry.size.height) / 2
      let correction = grading[selection]
      let angle = correction.hue / 180 * .pi
      let distance = correction.saturation / 100 * radius
      ZStack {
        Circle()
          .fill(AngularGradient(
            colors: (0...12).map { Color(hue: Double($0) / 12, saturation: 1, brightness: 1) },
            center: .center
          ))
        Circle()
          .fill(RadialGradient(colors: [.white, .white.opacity(0)],
            center: .center, startRadius: 0, endRadius: radius))
        Circle().stroke(.white.opacity(0.25), lineWidth: 1)
        Circle()
          .fill(Color(hue: correction.hue / 360, saturation: correction.saturation / 100, brightness: 1))
          .overlay(Circle().stroke(.black, lineWidth: 3))
          .overlay(Circle().stroke(.white, lineWidth: 1))
          .frame(width: 12, height: 12)
          .offset(x: cos(angle) * distance, y: sin(angle) * distance)
      }
      .contentShape(Circle())
      .gesture(DragGesture(minimumDistance: 0)
        .onChanged { onChange(wheelValue(at: $0.location, radius: radius)) }
        .onEnded { onEnd(wheelValue(at: $0.location, radius: radius)) })
    }
    .accessibilityHidden(true)
  }

  private func wheelValue(at point: CGPoint, radius: CGFloat) -> ColorGradingFeature {
    var next = grading
    let x = point.x - radius
    let y = point.y - radius
    let distance = hypot(x, y)
    // At the origin hue has no geometric meaning: preserve the authored hue.
    if distance > 0.5 {
      next[selection].hue = (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
    next[selection].saturation = min(distance / max(radius, 1) * 100, 100)
    return next
  }

  private func correctionSlider(
    _ title: String,
    axis: WritableKeyPath<ColorGradingFeature.Correction, Double>,
    range: ClosedRange<Double>
  ) -> some View {
    valueSlider(title, value: grading[selection][keyPath: axis], range: range) { value in
      var next = grading
      next[selection][keyPath: axis] = value
      pendingSliderValue = next
      onChange(next)
    }
  }

  private func gradingSlider(
    _ title: String,
    axis: WritableKeyPath<ColorGradingFeature, Double>,
    range: ClosedRange<Double>
  ) -> some View {
    valueSlider(title, value: grading[keyPath: axis], range: range) { value in
      var next = grading
      next[keyPath: axis] = value
      pendingSliderValue = next
      onChange(next)
    }
  }

  private func valueSlider(
    _ title: String, value: Double, range: ClosedRange<Double>, set: @escaping (Double) -> Void
  ) -> some View {
    HStack(spacing: 8) {
      Text(title).frame(width: 64, alignment: .leading)
      Slider(value: Binding(get: { value }, set: { set($0) }), in: range, step: 1) { editing in
        if !editing, let pendingSliderValue {
          onEnd(pendingSliderValue)
          self.pendingSliderValue = nil
        }
      }
      .accessibilityLabel(title)
      .accessibilityValue("\(Int(value.rounded()))")
      .accessibilityIdentifier("image-editor.grading.\(title.lowercased())")
      Text(value, format: .number.precision(.fractionLength(0)))
        .monospacedDigit()
        .frame(width: 28, alignment: .trailing)
        .accessibilityHidden(true)
    }
    .font(.caption2)
  }
}
