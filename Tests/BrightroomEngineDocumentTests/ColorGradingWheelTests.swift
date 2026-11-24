#if os(macOS)

import AppKit
import Observation
import SwiftUI
import Testing

import BrightroomParametric
@testable import BrightroomUI

/// The grading wheel alone, 100 points square in the middle of a window off
/// every screen: where a press puts the puck, which drags end an operation
/// and when, and how its keyboard steps. Clicks and keys go to the window
/// in-process, and the keyboard view is also driven through the methods
/// AppKit calls; nothing is posted to the system.
@MainActor
struct ColorGradingWheelTests {

  typealias Correction = ColorGradingFeature.Correction
  typealias Responder = ColorGradingWheel.Keyboard.Responder

  /// What the wheel reports, and whether it shows, is enabled and has moved
  /// 20 points right. The wheel shows each value it reports, as the editor's
  /// preview does.
  @MainActor
  @Observable
  final class Recorder {
    var correction: Correction
    var isShown = true
    var isEnabled = true
    var isMoved = false
    private(set) var changes: [Correction] = []
    private(set) var ends: [Correction] = []
    private(set) var laterEnds = 0

    init(_ correction: Correction) {
      self.correction = correction
    }

    func change(_ correction: Correction) {
      changes.append(correction)
      self.correction = correction
    }

    func end(_ correction: Correction) {
      ends.append(correction)
      self.correction = correction
    }

    func endLater() {
      laterEnds += 1
    }
  }

  struct Host: View {
    let recorder: Recorder
    let interaction: ColorGradingWheel.Interaction

    var body: some View {
      ZStack {
        if recorder.isShown {
          ColorGradingWheel(
            correction: recorder.correction,
            rangeName: "Shadows",
            interaction: interaction,
            onChange: { recorder.change($0) },
            onEnd: { recorder.end($0) },
            onEndLater: { recorder.endLater() }
          )
          .frame(width: 100, height: 100)
          .disabled(recorder.isEnabled == false)
          // The padded wheel stays centred, so the wheel moves half of it.
          .padding(.leading, recorder.isMoved ? 40 : 0)
        }
      }
      .frame(width: 200, height: 200)
    }
  }

  /// The wheel in a 200-point window, ordered in far off every screen,
  /// because SwiftUI handles clicks only in a window that is ordered in.
  @MainActor
  final class Mounted {

    let recorder: Recorder
    let window: NSWindow
    let hostingView: NSView

    init(_ correction: Correction, interaction: ColorGradingWheel.Interaction = .pointer) {
      _ = NSApplication.shared
      recorder = Recorder(correction)
      hostingView = NSHostingView(rootView: Host(recorder: recorder, interaction: interaction))
      window = NSWindow(
        contentRect: CGRect(x: -5000, y: -5000, width: 200, height: 200),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
      )
      window.isReleasedWhenClosed = false
      window.contentView = hostingView
      window.orderFrontRegardless()
    }

    /// The wheel's keyboard view, while the wheel shows one.
    var responder: Responder? {
      Self.first(Responder.self, in: hostingView)
    }

    func press(at point: CGPoint, clickCount: Int = 1) throws {
      try send(.leftMouseDown, at: point, clickCount: clickCount)
    }

    func drag(to point: CGPoint) throws {
      try send(.leftMouseDragged, at: point)
    }

    func release(at point: CGPoint, clickCount: Int = 1) throws {
      try send(.leftMouseUp, at: point, clickCount: clickCount)
    }

    /// A key-down or key-up of the arrow `key` in the window, as the
    /// keyboard would send it while the window is key.
    func key(
      _ type: NSEvent.EventType,
      _ key: NSEvent.SpecialKey,
      modifiers: NSEvent.ModifierFlags = [],
      isRepeat: Bool = false
    ) throws {
      let characters = String(Character(try #require(Unicode.Scalar(UInt32(key.rawValue)))))
      // kVK_LeftArrow, kVK_RightArrow, kVK_DownArrow and kVK_UpArrow.
      let keyCode: UInt16 = switch key {
      case .leftArrow: 123
      case .rightArrow: 124
      case .downArrow: 125
      default: 126
      }
      let event = try #require(
        NSEvent.keyEvent(
          with: type,
          location: .zero,
          modifierFlags: modifiers.union([.numericPad, .function]),
          timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber,
          context: nil,
          characters: characters,
          charactersIgnoringModifiers: characters,
          isARepeat: isRepeat,
          keyCode: keyCode
        )
      )
      window.sendEvent(event)
    }

    /// Command going down.
    func commandDown() throws -> NSEvent {
      try #require(
        NSEvent.keyEvent(
          with: .flagsChanged,
          location: .zero,
          modifierFlags: .command,
          timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber,
          context: nil,
          characters: "",
          charactersIgnoringModifiers: "",
          isARepeat: false,
          // kVK_Command
          keyCode: 55
        )
      )
    }

    /// Lays the window out for ten ticks, so the wheel follows what changed
    /// and work deferred to a later turn runs.
    func settle() async throws {
      for _ in 0..<10 {
        hostingView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
      }
    }

    func close() {
      window.orderOut(nil)
      window.contentView = nil
      window.close()
    }

    /// Sends a mouse event at `point` in the wheel, whose top-left corner is
    /// at (50, 150) in the window, whose coordinates run up.
    private func send(_ type: NSEvent.EventType, at point: CGPoint, clickCount: Int = 1) throws {
      let event = try #require(
        NSEvent.mouseEvent(
          with: type,
          location: CGPoint(x: 50 + point.x, y: 150 - point.y),
          modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber,
          context: nil,
          eventNumber: 0,
          clickCount: clickCount,
          pressure: type == .leftMouseUp ? 0 : 1
        )
      )
      window.sendEvent(event)
    }

    private static func first<View: NSView>(_ type: View.Type, in view: NSView) -> View? {
      if let match = view as? View {
        return match
      }
      for subview in view.subviews {
        if let match = first(type, in: subview) {
          return match
        }
      }
      return nil
    }
  }

  /// Hue 0 at saturation 40: in the 100-point wheel, the puck's center is
  /// at (70, 50), 20 points right of the wheel's.
  static let tint = Correction(hue: 0, saturation: 40, luminance: 20)

  /// Whether `lhs` and `rhs` are the same correction, to rounding.
  static func isClose(_ lhs: Correction?, _ rhs: Correction) -> Bool {
    guard let lhs else {
      return false
    }
    return abs(lhs.hue - rhs.hue) < 1e-6
      && abs(lhs.saturation - rhs.saturation) < 1e-6
      && lhs.luminance == rhs.luminance
  }

  // MARK: - Pointer

  @Test func `A press within 8 points of the puck drags it from where it is`() async throws {
    let mounted = Mounted(Self.tint)
    defer { mounted.close() }
    try await mounted.settle()

    // 5 points above the puck's center.
    try mounted.press(at: CGPoint(x: 70, y: 45))
    try await mounted.settle()
    #expect(mounted.recorder.changes.isEmpty, "The press moved the puck.")

    try mounted.drag(to: CGPoint(x: 80, y: 45))
    try await mounted.settle()
    try mounted.release(at: CGPoint(x: 80, y: 45))
    try await mounted.settle()

    // The puck moved 10 points right, from (70, 50) to (80, 50).
    let moved = Correction(hue: 0, saturation: 60, luminance: 20)
    #expect(Self.isClose(mounted.recorder.changes.last, moved))
    #expect(mounted.recorder.ends.count == 1)
    #expect(Self.isClose(mounted.recorder.ends.first, moved))
    #expect(mounted.recorder.laterEnds == 0)
  }

  @Test func `A press farther than 8 points from the puck puts the puck under it`() async throws {
    let mounted = Mounted(Self.tint)
    defer { mounted.close() }
    try await mounted.settle()

    // 11 points below the puck's center, at (20, 11) from the wheel's.
    try mounted.press(at: CGPoint(x: 70, y: 61))
    try await mounted.settle()
    let pressed = Correction(
      hue: atan2(11, 20) * 180 / .pi,
      saturation: hypot(20, 11) / 50 * 100,
      luminance: 20
    )
    #expect(mounted.recorder.changes.count == 1)
    #expect(Self.isClose(mounted.recorder.changes.first, pressed))

    try mounted.release(at: CGPoint(x: 70, y: 61))
    try await mounted.settle()
    #expect(mounted.recorder.ends.count == 1)
    #expect(Self.isClose(mounted.recorder.ends.first, pressed))
  }

  @Test func `With touch, a press puts the puck under it however near it lands`() async throws {
    let mounted = Mounted(Self.tint, interaction: .touch)
    defer { mounted.close() }
    try await mounted.settle()
    #expect(mounted.responder == nil, "Touch takes no keys.")

    // 5 points above the puck's center, at (20, -5) from the wheel's.
    try mounted.press(at: CGPoint(x: 70, y: 45))
    try await mounted.settle()
    let pressed = Correction(
      hue: atan2(-5, 20) * 180 / .pi + 360,
      saturation: hypot(20, 5) / 50 * 100,
      luminance: 20
    )
    #expect(mounted.recorder.changes.count == 1)
    #expect(Self.isClose(mounted.recorder.changes.first, pressed))

    try mounted.release(at: CGPoint(x: 70, y: 45))
    try await mounted.settle()
    #expect(mounted.recorder.ends.count == 1)
    #expect(Self.isClose(mounted.recorder.ends.first, pressed))
  }

  @Test func `A click on the puck reports nothing, so a double-click on it resets the correction once`() async throws {
    let mounted = Mounted(Self.tint)
    defer { mounted.close() }
    try await mounted.settle()

    let puck = CGPoint(x: 70, y: 50)
    try mounted.press(at: puck, clickCount: 1)
    try mounted.release(at: puck, clickCount: 1)
    try mounted.press(at: puck, clickCount: 2)
    try mounted.release(at: puck, clickCount: 2)
    try await mounted.settle()

    #expect(mounted.recorder.changes.isEmpty)
    #expect(mounted.recorder.ends == [Correction()], "The reset clears the luminance too.")
  }

  @Test func `A drag that SwiftUI cancels ends once, through onEndLater`() async throws {
    let mounted = Mounted(Self.tint)
    defer { mounted.close() }
    try await mounted.settle()
    try mounted.press(at: CGPoint(x: 70, y: 50))
    try mounted.drag(to: CGPoint(x: 80, y: 50))
    try await mounted.settle()
    #expect(mounted.recorder.changes.isEmpty == false)

    // Disabling the wheel cancels its drag without `onEnded`.
    mounted.recorder.isEnabled = false
    try await mounted.settle()
    #expect(mounted.recorder.laterEnds == 1)

    try mounted.release(at: CGPoint(x: 80, y: 50))
    try await mounted.settle()
    #expect(mounted.recorder.ends.isEmpty)
    #expect(mounted.recorder.laterEnds == 1)
  }

  @Test func `A drag that the wheel leaving cuts short ends once, through onEndLater`() async throws {
    let mounted = Mounted(Self.tint)
    defer { mounted.close() }
    try await mounted.settle()
    try mounted.press(at: CGPoint(x: 70, y: 50))
    try mounted.drag(to: CGPoint(x: 80, y: 50))
    try await mounted.settle()
    #expect(mounted.recorder.changes.isEmpty == false)

    mounted.recorder.isShown = false
    try await mounted.settle()
    #expect(mounted.recorder.laterEnds == 1)

    try mounted.release(at: CGPoint(x: 80, y: 50))
    try await mounted.settle()
    #expect(mounted.recorder.ends.isEmpty)
    #expect(mounted.recorder.laterEnds == 1)
  }

  @Test func `A drag whose wheel moves ends once through onEndLater, and the rest of its gesture reports nothing`() async throws {
    let mounted = Mounted(Self.tint)
    defer { mounted.close() }
    try await mounted.settle()
    try mounted.press(at: CGPoint(x: 70, y: 50))
    try mounted.drag(to: CGPoint(x: 80, y: 50))
    try await mounted.settle()
    let changes = mounted.recorder.changes
    #expect(changes.isEmpty == false)

    mounted.recorder.isMoved = true
    try await mounted.settle()
    #expect(mounted.recorder.laterEnds == 1)

    // The pointer goes on, then comes up.
    try mounted.drag(to: CGPoint(x: 90, y: 50))
    try mounted.release(at: CGPoint(x: 90, y: 50))
    try await mounted.settle()
    #expect(mounted.recorder.changes == changes)
    #expect(mounted.recorder.ends.isEmpty)
    #expect(mounted.recorder.laterEnds == 1)

    // Back in place, the next drag is one of its own.
    mounted.recorder.isMoved = false
    try await mounted.settle()
    try mounted.press(at: CGPoint(x: 50, y: 20))
    try mounted.release(at: CGPoint(x: 50, y: 20))
    try await mounted.settle()
    #expect(mounted.recorder.ends.count == 1)
    #expect(mounted.recorder.laterEnds == 1)
  }

  @Test func `A press on the puck that the wheel leaving cuts short ends nothing`() async throws {
    let mounted = Mounted(Self.tint)
    defer { mounted.close() }
    try await mounted.settle()
    try mounted.press(at: CGPoint(x: 70, y: 50))
    try await mounted.settle()

    mounted.recorder.isShown = false
    try await mounted.settle()
    #expect(mounted.recorder.changes.isEmpty)
    #expect(mounted.recorder.laterEnds == 0)
  }

  // MARK: - Keyboard

  @Test func `The keyboard view covers the wheel, takes no clicks and is a key view only under Full Keyboard Access`() async throws {
    let mounted = Mounted(Self.tint)
    defer { mounted.close() }
    try await mounted.settle()
    let responder = try #require(mounted.responder)

    #expect(responder.convert(responder.bounds, to: nil) == CGRect(x: 50, y: 50, width: 100, height: 100))
    #expect(responder.focusRingMaskBounds == responder.bounds)
    #expect(responder.hitTest(CGPoint(x: responder.bounds.midX, y: responder.bounds.midY)) == nil)
    #expect(responder.isAccessibilityElement() == false)
    #expect(responder.acceptsFirstResponder)
    // Without Full Keyboard Access, the window's key view loop passes it by.
    if NSApp.isFullKeyboardAccessEnabled == false {
      #expect(responder.canBecomeKeyView == false)
    }
  }

  @Test func `The arrow keys step the hue and the saturation, ten times as far with Shift, and each key-up ends once`() async throws {
    let mounted = Mounted(Correction(hue: 30, saturation: 40))
    defer { mounted.close() }
    try await mounted.settle()
    let responder = try #require(mounted.responder)
    #expect(mounted.window.makeFirstResponder(responder))

    let presses: [(NSEvent.SpecialKey, NSEvent.ModifierFlags, Correction)] = [
      (.rightArrow, [], Correction(hue: 31, saturation: 40)),
      (.leftArrow, .shift, Correction(hue: 21, saturation: 40)),
      (.upArrow, [], Correction(hue: 21, saturation: 41)),
      (.downArrow, .shift, Correction(hue: 21, saturation: 31)),
    ]
    for (index, (key, modifiers, stepped)) in presses.enumerated() {
      try mounted.key(.keyDown, key, modifiers: modifiers)
      #expect(mounted.recorder.changes.last == stepped)
      #expect(mounted.recorder.ends.count == index, "The key-down ended the step.")

      try mounted.key(.keyUp, key, modifiers: modifiers)
      #expect(mounted.recorder.ends.count == index + 1)
      #expect(mounted.recorder.ends.last == stepped)
      // The next press steps from what the wheel then shows.
      try await mounted.settle()
    }
    #expect(mounted.recorder.laterEnds == 0)
  }

  @Test func `A held arrow previews each repeat, and its key-up ends once`() async throws {
    let mounted = Mounted(Correction(hue: 30, saturation: 40))
    defer { mounted.close() }
    try await mounted.settle()
    let responder = try #require(mounted.responder)
    #expect(mounted.window.makeFirstResponder(responder))

    try mounted.key(.keyDown, .rightArrow)
    for _ in 0..<4 {
      try mounted.key(.keyDown, .rightArrow, isRepeat: true)
    }
    #expect(mounted.recorder.changes.map(\.hue) == [31, 32, 33, 34, 35])
    #expect(mounted.recorder.ends.isEmpty)

    try mounted.key(.keyUp, .rightArrow)
    #expect(mounted.recorder.ends == [Correction(hue: 35, saturation: 40)])
  }

  @Test func `The hue steps around the wheel, and the saturation stops at its ends`() {
    func stepped(_ correction: Correction, _ direction: MoveCommandDirection, by amount: Double) -> Correction {
      Responder.stepped(correction, toward: direction, by: amount)
    }

    #expect(abs(stepped(Correction(hue: 359.5), .right, by: 1).hue - 0.5) < 1e-9)
    #expect(stepped(Correction(hue: 0), .left, by: 1).hue == 359)
    #expect(stepped(Correction(hue: 360), .right, by: 1).hue == 1)
    #expect(stepped(Correction(hue: 5), .left, by: 10).hue == 355)
    #expect(stepped(Correction(saturation: 95), .up, by: 10).saturation == 100)
    #expect(stepped(Correction(saturation: 5), .down, by: 10).saturation == 0)
    // The other axis and the luminance stay.
    #expect(stepped(Correction(hue: 30, saturation: 40, luminance: -20), .up, by: 1) == Correction(hue: 30, saturation: 41, luminance: -20))
  }

  @Test func `Command going down ends a key step, and an arrow pressed with Command steps nothing`() async throws {
    let mounted = Mounted(Correction(hue: 30, saturation: 40))
    defer { mounted.close() }
    try await mounted.settle()
    let responder = try #require(mounted.responder)

    responder.step(.right, modifiers: [])
    #expect(mounted.recorder.ends.isEmpty)
    responder.flagsChanged(with: try mounted.commandDown())
    #expect(mounted.recorder.ends == [Correction(hue: 31, saturation: 40)])

    responder.step(.right, modifiers: .command)
    #expect(mounted.recorder.changes.count == 1)
  }

  @Test func `Losing focus, the window resigning key or the wheel leaving ends a key step through onEndLater`() async throws {
    let mounted = Mounted(Correction(hue: 30, saturation: 40))
    defer { mounted.close() }
    try await mounted.settle()
    let responder = try #require(mounted.responder)

    #expect(mounted.window.makeFirstResponder(responder))
    responder.step(.right, modifiers: [])
    #expect(mounted.window.makeFirstResponder(nil))
    try await mounted.settle()
    #expect(mounted.recorder.laterEnds == 1)

    responder.step(.right, modifiers: [])
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: mounted.window)
    try await mounted.settle()
    #expect(mounted.recorder.laterEnds == 2)

    responder.step(.right, modifiers: [])
    mounted.recorder.isShown = false
    try await mounted.settle()
    #expect(responder.window == nil)
    #expect(mounted.recorder.laterEnds == 3)
    #expect(mounted.recorder.ends.isEmpty)
  }

  @Test func `A disabled wheel takes no focus, and its keys step nothing`() async throws {
    let mounted = Mounted(Correction(hue: 30, saturation: 40))
    defer { mounted.close() }
    mounted.recorder.isEnabled = false
    try await mounted.settle()
    let responder = try #require(mounted.responder)

    #expect(responder.acceptsFirstResponder == false)
    responder.step(.right, modifiers: [])
    #expect(mounted.recorder.changes.isEmpty)
  }
}

#endif
