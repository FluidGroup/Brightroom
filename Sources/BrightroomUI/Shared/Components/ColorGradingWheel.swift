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

import BrightroomParametric
import SwiftUI

/// A hue and saturation wheel for one tonal range of color grading: the angle
/// is the hue, and the distance from the center is the saturation.
///
/// A drag reports each value with `onChange` and the last one with `onEnd`.
/// A drag that SwiftUI cancels, or that the wheel leaving the screen cuts
/// short, ends through `onEndLater` instead. VoiceOver reads the wheel as two
/// sliders, hue and saturation, in steps of 5; each step is reported with
/// `onChange` and then `onEnd`, so it is a completed change of its own.
struct ColorGradingWheel: View {

  /// How a press moves the puck, and what else the wheel takes.
  enum Interaction {
    /// A press puts the puck under it, wherever it lands: a finger hides the
    /// puck.
    case touch
    /// A press within `grabRadius` of the puck's center drags the puck from
    /// where it is, and a press elsewhere puts the puck under it. A click
    /// that moves nothing reports nothing, and a double-click resets the
    /// correction with one `onEnd`. A drag whose wheel moves under it, as
    /// when an inspector hides, ends through `onEndLater`, and the rest of
    /// its gesture reports nothing. On the Mac the wheel also takes focus as
    /// a control does, and the arrow keys step it (`Keyboard`).
    case pointer
  }

  /// How far from the puck's center a press grabs the puck: the 12-point
  /// puck and the stroke around it, on the 4-point grid.
  private static let grabRadius: CGFloat = 8

  private let correction: ColorGradingFeature.Correction
  private let rangeName: String
  private let interaction: Interaction
  private let onChange: (ColorGradingFeature.Correction) -> Void
  private let onEnd: (ColorGradingFeature.Correction) -> Void
  private let onEndLater: () -> Void

  /// Whether a drag is in progress. SwiftUI resets it when a drag ends, and
  /// when it cancels one, which it does without `onEnded`.
  @GestureState private var isDragging = false

  /// The drag in progress. The wheel draws nothing from it, so it is not
  /// observed.
  @State private var drag = Drag()

  /// `rangeName` begins the VoiceOver labels of the sliders ("Shadows Hue").
  /// `onEndLater` ends a drag that ended without its end on the next
  /// main-actor turn, so that nothing is written inside a view update; it
  /// carries no value.
  init(
    correction: ColorGradingFeature.Correction,
    rangeName: String,
    interaction: Interaction = .touch,
    onChange: @escaping (ColorGradingFeature.Correction) -> Void,
    onEnd: @escaping (ColorGradingFeature.Correction) -> Void,
    onEndLater: @escaping () -> Void = {}
  ) {
    self.correction = correction
    self.rangeName = rangeName
    self.interaction = interaction
    self.onChange = onChange
    self.onEnd = onEnd
    self.onEndLater = onEndLater
  }

  var body: some View {
    GeometryReader { geometry in
      let radius = min(geometry.size.width, geometry.size.height) / 2
      let puckOffset = puckOffset(radius: radius)
      ZStack {
        Circle()
          .fill(
            AngularGradient(
              colors: (0...12).map { Color(hue: Double($0) / 12, saturation: 1, brightness: 1) },
              center: .center
            )
          )
        Circle()
          .fill(
            RadialGradient(
              colors: [.white, .white.opacity(0)],
              center: .center,
              startRadius: 0,
              endRadius: radius
            )
          )
        Circle()
          .stroke(.white.opacity(0.25), lineWidth: 1)
        Circle()
          .fill(Color(hue: correction.hue / 360, saturation: correction.saturation / 100, brightness: 1))
          .overlay(Circle().stroke(.black, lineWidth: 3))
          .overlay(Circle().stroke(.white, lineWidth: 1))
          .frame(width: 12, height: 12)
          .offset(puckOffset)
      }
      .contentShape(Circle())
      .gesture(dragGesture(radius: radius, puckOffset: puckOffset))
      .simultaneousGesture(interaction == .pointer ? resetGesture : nil)
    }
    .onChange(of: isDragging) { _, isDragging in
      // A drag that ended with `onEnded` is over by now, so one still in
      // progress was cancelled.
      if isDragging == false {
        endDragLater()
      }
    }
    .onDisappear {
      endDragLater()
    }
    .onGeometryChange(for: CGRect.self) { geometry in
      geometry.frame(in: .global)
    } action: { _ in
      endDragOnMove()
    }
    #if os(macOS)
    .overlay {
      if interaction == .pointer {
        Keyboard(correction: correction, onChange: onChange, onEnd: onEnd, onEndLater: onEndLater)
          .allowsHitTesting(false)
      }
    }
    #endif
    .accessibilityRepresentation {
      VStack {
        slider("Hue", axis: \.hue, range: 0...360)
        slider("Saturation", axis: \.saturation, range: 0...100)
      }
    }
  }

  /// Moves the puck from a press to its release.
  private func dragGesture(radius: CGFloat, puckOffset: CGSize) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .updating($isDragging) { _, isDragging, _ in
        isDragging = true
      }
      .onChanged { value in
        if case .idle = drag.phase {
          let grabbedPuck = grabbedPuck(at: value.startLocation, radius: radius, puckOffset: puckOffset)
          drag.phase = .moving(grabbedPuck: grabbedPuck, hasChanged: false)
        }
        guard case .moving(let grabbedPuck, let hasChanged) = drag.phase else {
          return
        }
        // A press that grabs the puck moves nothing until the pointer does.
        guard hasChanged || grabbedPuck == nil || value.translation != .zero else {
          return
        }
        drag.phase = .moving(grabbedPuck: grabbedPuck, hasChanged: true)
        onChange(wheelValue(at: Drag.puckPoint(for: value, grabbedPuck: grabbedPuck), radius: radius))
      }
      .onEnded { value in
        let phase = drag.phase
        drag.phase = .idle
        // A click on the puck moves nothing, so it ends nothing.
        guard case .moving(let grabbedPuck, true) = phase else {
          return
        }
        onEnd(wheelValue(at: Drag.puckPoint(for: value, grabbedPuck: grabbedPuck), radius: radius))
      }
  }

  private var resetGesture: some Gesture {
    TapGesture(count: 2)
      .onEnded {
        onEnd(.init())
      }
  }

  /// Ends a drag still in progress, when SwiftUI cancels it or removes the
  /// wheel.
  private func endDragLater() {
    let phase = drag.phase
    drag.phase = .idle
    if case .moving(_, true) = phase {
      endLater()
    }
  }

  /// Ends a pointer's drag whose wheel moves under it, which would otherwise
  /// put the puck where the moved wheel finds the pointer. The rest of its
  /// gesture reports nothing.
  private func endDragOnMove() {
    guard interaction == .pointer, case .moving(_, let hasChanged) = drag.phase else {
      return
    }

    drag.phase = .ended
    if hasChanged {
      endLater()
    }
  }

  /// Calls `onEndLater` on the next turn: SwiftUI cancels a drag, removes
  /// the wheel and reports its geometry inside a view update, where nothing
  /// may be written.
  private func endLater() {
    let onEndLater = onEndLater
    Task { @MainActor in
      onEndLater()
    }
  }

  /// Where the puck is from the wheel's center, in a wheel of `radius`.
  private func puckOffset(radius: CGFloat) -> CGSize {
    let angle = correction.hue / 180 * .pi
    let distance = correction.saturation / 100 * radius
    return CGSize(width: cos(angle) * distance, height: sin(angle) * distance)
  }

  /// The puck's center when a press at `press` grabs the puck: within
  /// `grabRadius` of it, with a pointer. nil when the press puts the puck
  /// under it.
  private func grabbedPuck(at press: CGPoint, radius: CGFloat, puckOffset: CGSize) -> CGPoint? {
    let puck = CGPoint(x: radius + puckOffset.width, y: radius + puckOffset.height)
    guard interaction == .pointer, hypot(press.x - puck.x, press.y - puck.y) <= Self.grabRadius else {
      return nil
    }
    return puck
  }

  private func wheelValue(at point: CGPoint, radius: CGFloat) -> ColorGradingFeature.Correction {
    var next = correction
    let x = point.x - radius
    let y = point.y - radius
    let distance = hypot(x, y)
    // At the origin hue has no geometric meaning: preserve the authored hue.
    if distance > 0.5 {
      next.hue = (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
    next.saturation = min(distance / max(radius, 1) * 100, 100)
    return next
  }

  private func slider(
    _ axisName: String,
    axis: WritableKeyPath<ColorGradingFeature.Correction, Double>,
    range: ClosedRange<Double>
  ) -> some View {
    let value = correction[keyPath: axis]
    let label = "\(rangeName) \(axisName)"
    return Slider(
      value: Binding(
        get: { value },
        set: { newValue in
          var next = correction
          next[keyPath: axis] = newValue
          guard next != correction else {
            return
          }
          onChange(next)
          onEnd(next)
        }
      ),
      in: range,
      step: 5
    ) {
      Text(label)
    }
    .accessibilityValue("\(Int(value.rounded()))")
  }
}

extension ColorGradingWheel {

  /// A drag, from its first change to the end of its gesture.
  private final class Drag {

    enum Phase {
      /// No drag.
      case idle
      /// A drag in progress: where the puck was when the press grabbed it,
      /// nil when the press put the puck under it, and whether the drag has
      /// reported a value, so that its end ends an operation.
      case moving(grabbedPuck: CGPoint?, hasChanged: Bool)
      /// A drag that ended when its wheel moved, while its gesture goes on.
      case ended
    }

    var phase = Phase.idle

    /// Where a drag puts the puck: moved with the pointer from where it was,
    /// when the press grabbed it, and otherwise under the pointer.
    static func puckPoint(for value: DragGesture.Value, grabbedPuck: CGPoint?) -> CGPoint {
      guard let grabbedPuck else {
        return value.location
      }
      return CGPoint(
        x: grabbedPuck.x + value.translation.width,
        y: grabbedPuck.y + value.translation.height
      )
    }
  }
}
