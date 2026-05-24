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

import SwiftUI

struct BrightroomSteppedSlider<TopMarker: View, Tick: View, ActiveTick: View>: View {

  @Binding var value: Double

  let range: ClosedRange<Double>
  let stepCount: Int
  let style: BrightroomSteppedSliderStyle
  let transform: (Double) -> Double
  let hapticIdentity: (Double) -> AnyHashable?
  let onHaptic: () -> Void
  let topMarker: (BrightroomSteppedSliderTickContext) -> TopMarker
  let tick: (BrightroomSteppedSliderTickContext) -> Tick
  let activeTick: (BrightroomSteppedSliderTickContext) -> ActiveTick

  @State private var scrollIndex: Int?
  @State private var lastHapticIdentity: AnyHashable?
  @State private var lastEmittedValue: Double?
  @State private var coordinateSpaceName = "BrightroomSteppedSlider.\(UUID().uuidString)"

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        ScrollView(.horizontal, showsIndicators: false) {
          LazyHStack(spacing: style.tickSpacing) {
            ForEach(0...stepCount, id: \.self) { index in
              let context = tickContext(for: index)

              BrightroomSteppedSliderTickItem(
                context: context,
                style: style,
                viewportWidth: proxy.size.width,
                coordinateSpaceName: coordinateSpaceName,
                topMarker: topMarker,
                tick: tick,
                activeTick: activeTick
              )
              .id(index)
              .frame(width: style.tickWidth)
            }
          }
          .scrollTargetLayout()
        }
        .contentMargins(.horizontal, contentMargin(for: proxy.size.width))
        .scrollPosition(id: $scrollIndex, anchor: .center)
        .scrollTargetBehavior(.brightroomSteppedSliderSnap(step: Double(style.tickPitch)))
        .mask(BrightroomSteppedSliderMask())
        .coordinateSpace(name: coordinateSpaceName)
      }
    }
    .onAppear {
      scrollIndex = index(for: value)
    }
    .onChange(of: value) { _, newValue in
      if let lastEmittedValue, Self.isEquivalent(newValue, to: lastEmittedValue) {
        self.lastEmittedValue = nil
        return
      }

      let index = index(for: newValue)
      guard index != scrollIndex else {
        return
      }

      withAnimation(.smooth) {
        scrollIndex = index
      }
    }
    .onChange(of: scrollIndex) { _, newIndex in
      guard let newIndex else {
        return
      }

      let newValue = value(for: newIndex)
      triggerHapticIfNeeded(for: newValue)
      lastEmittedValue = newValue

      guard !Self.isEquivalent(value, to: newValue) else {
        return
      }

      value = newValue
    }
  }

  private func contentMargin(for width: CGFloat) -> CGFloat {
    max(0, width / 2 - style.tickWidth / 2)
  }

  private func tickContext(for index: Int) -> BrightroomSteppedSliderTickContext {
    .init(
      index: index,
      value: rawValue(for: index),
      isMajor: index.isMultiple(of: max(1, style.majorTickInterval))
    )
  }

  private func rawValue(for index: Int) -> Double {
    let ratio = Double(index) / Double(stepCount)
    return range.lowerBound + (range.upperBound - range.lowerBound) * ratio
  }

  private func value(for index: Int) -> Double {
    transform(rawValue(for: index).clamped(to: range))
  }

  private func index(for value: Double) -> Int {
    guard range.lowerBound != range.upperBound else {
      return 0
    }

    let ratio = ((value - range.lowerBound) / (range.upperBound - range.lowerBound))
      .clamped(to: 0...1)
    return Int((ratio * Double(stepCount)).rounded())
  }

  private func triggerHapticIfNeeded(for value: Double) {
    guard let identity = hapticIdentity(value) else {
      lastHapticIdentity = nil
      return
    }

    guard identity != lastHapticIdentity else {
      return
    }

    lastHapticIdentity = identity
    onHaptic()
  }

  nonisolated private static func isEquivalent(_ lhs: Double, to rhs: Double) -> Bool {
    abs(lhs - rhs) < 0.000_001
  }
}

struct BrightroomSteppedSliderStyle {
  var tickWidth: CGFloat
  var tickSpacing: CGFloat
  var tickHeight: CGFloat
  var activeTickHeight: CGFloat
  var majorTickInterval: Int

  var tickPitch: CGFloat {
    tickWidth + tickSpacing
  }
}

struct BrightroomSteppedSliderTickContext {
  let index: Int
  let value: Double
  let isMajor: Bool
}

private struct BrightroomSteppedSliderTickItem<TopMarker: View, Tick: View, ActiveTick: View>: View {

  let context: BrightroomSteppedSliderTickContext
  let style: BrightroomSteppedSliderStyle
  let viewportWidth: CGFloat
  let coordinateSpaceName: String
  let topMarker: (BrightroomSteppedSliderTickContext) -> TopMarker
  let tick: (BrightroomSteppedSliderTickContext) -> Tick
  let activeTick: (BrightroomSteppedSliderTickContext) -> ActiveTick

  var body: some View {
    VStack(spacing: 3) {
      topMarker(context)

      ZStack {
        tick(context)

        activeTick(context)
          .visualEffect { content, proxy in
            content
              .opacity(Double(Self.activeProgress(
                in: proxy,
                viewportWidth: viewportWidth,
                coordinateSpaceName: coordinateSpaceName,
                tickPitch: style.tickPitch
              )))
              .scaleEffect(
                x: 1,
                y: Self.scale(
                  activeProgress: Self.activeProgress(
                    in: proxy,
                    viewportWidth: viewportWidth,
                    coordinateSpaceName: coordinateSpaceName,
                    tickPitch: style.tickPitch
                  ),
                  style: style
                ),
                anchor: .center
              )
          }
      }
      .frame(width: style.tickWidth, height: style.tickHeight)
    }
    .frame(height: style.activeTickHeight + 9)
  }

  nonisolated private static func activeProgress(
    in proxy: GeometryProxy,
    viewportWidth: CGFloat,
    coordinateSpaceName: String,
    tickPitch: CGFloat
  ) -> CGFloat {
    let centerX = proxy.frame(in: .named(coordinateSpaceName)).midX
    let distance = abs(centerX - viewportWidth / 2)
    return max(0, 1 - distance / tickPitch)
  }

  nonisolated private static func scale(
    activeProgress: CGFloat,
    style: BrightroomSteppedSliderStyle
  ) -> CGFloat {
    let heightRatio = style.activeTickHeight / style.tickHeight
    return 1 + (heightRatio - 1) * activeProgress
  }
}

private struct BrightroomSteppedSliderMask: View {
  var body: some View {
    HStack(spacing: 0) {
      LinearGradient(
        colors: [.black.opacity(0), .black],
        startPoint: .leading,
        endPoint: .trailing
      )
      .frame(width: 24)

      Color.black

      LinearGradient(
        colors: [.black, .black.opacity(0)],
        startPoint: .leading,
        endPoint: .trailing
      )
      .frame(width: 24)
    }
  }
}

private struct BrightroomSteppedSliderSnapBehavior: ScrollTargetBehavior {

  let step: Double

  func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
    guard step > 0 else {
      return
    }

    let lower = floor(target.rect.origin.x / step) * step
    let upper = lower + step

    if abs(target.rect.origin.x - lower) <= abs(target.rect.origin.x - upper) {
      target.rect.origin.x = lower
    } else {
      target.rect.origin.x = upper
    }
  }
}

private extension ScrollTargetBehavior where Self == BrightroomSteppedSliderSnapBehavior {
  static func brightroomSteppedSliderSnap(step: Double) -> BrightroomSteppedSliderSnapBehavior {
    .init(step: step)
  }
}

private extension Double {
  func clamped(to range: ClosedRange<Double>) -> Double {
    min(max(self, range.lowerBound), range.upperBound)
  }
}

#if DEBUG
#Preview("Brightroom Stepped Slider") {
  BrightroomSteppedSliderPreview()
}

private struct BrightroomSteppedSliderPreview: View {

  @State private var exposureValue: Double = 0
  @State private var rotationValue: Double = -12
  @State private var strengthValue: Double = 0.38

  var body: some View {
    VStack(spacing: 28) {
      previewItem(
        title: "Centered",
        value: $exposureValue,
        range: -1...1,
        stepCount: 200,
        style: .previewDense,
        accent: .red,
        markerValue: 0
      )

      previewItem(
        title: "Rotation",
        value: $rotationValue,
        range: -45...45,
        stepCount: 90,
        style: .previewRotation,
        accent: .white,
        markerValue: 0
      )
      .padding(.vertical, 12)
      .padding(.horizontal, 16)
      .background(Color.black)

      previewItem(
        title: "Positive Only",
        value: $strengthValue,
        range: 0...1,
        stepCount: 100,
        style: .previewDense,
        accent: .blue,
        markerValue: 0
      )
    }
    .padding(24)
    .frame(width: 560)
  }

  private func previewItem(
    title: String,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    stepCount: Int,
    style: BrightroomSteppedSliderStyle,
    accent: Color,
    markerValue: Double
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

      BrightroomSteppedSlider(
        value: value,
        range: range,
        stepCount: stepCount,
        style: style,
        transform: { $0 },
        hapticIdentity: { _ in nil },
        onHaptic: {},
        topMarker: { context in
          Circle()
            .frame(width: 6, height: 6)
            .opacity(context.isMarker(markerValue) && value.wrappedValue != markerValue ? 1 : 0)
        },
        tick: { context in
          Capsule()
            .foregroundStyle(context.isMajor ? Color.primary : Color.secondary)
        },
        activeTick: { _ in
          Capsule()
            .foregroundStyle(accent)
        }
      )
      .frame(height: 50)
      .tint(accent)
    }
  }
}

private extension BrightroomSteppedSliderStyle {
  static let previewDense = BrightroomSteppedSliderStyle(
    tickWidth: 2,
    tickSpacing: 4,
    tickHeight: 10,
    activeTickHeight: 18,
    majorTickInterval: 10
  )

  static let previewRotation = BrightroomSteppedSliderStyle(
    tickWidth: 1,
    tickSpacing: 4,
    tickHeight: 10,
    activeTickHeight: 18,
    majorTickInterval: 5
  )
}

private extension BrightroomSteppedSliderTickContext {
  func isMarker(_ markerValue: Double) -> Bool {
    abs(value - markerValue) < 0.000_001
  }
}
#endif
