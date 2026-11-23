#if os(macOS)

import AppKit
import Testing

@testable import BrightroomUI

/// The hold-key monitor's view in a window that reports key without being
/// ordered on screen: which built key events it consumes, and when the hold
/// starts and ends. Nothing is posted to the system.
@MainActor
struct HoldKeyMonitorTests {

  /// A window that reports key while `reportsKey` is true.
  final class KeyWindow: NSWindow {

    var reportsKey = true

    override var isKeyWindow: Bool {
      reportsKey
    }

    override var canBecomeKey: Bool {
      true
    }
  }

  /// A monitor of M in a key window, recording each hold change.
  @MainActor
  final class Fixture {

    var holds: [Bool] = []

    let window = Fixture.makeWindow()
    let view = HoldKeyMonitor.EventView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))

    init() {
      view.key = "m"
      view.isEnabled = true
      view.onHold = { [weak self] in
        self?.holds.append($0)
      }
      window.contentView?.addSubview(view)
    }

    static func makeWindow() -> KeyWindow {
      _ = NSApplication.shared
      let window = KeyWindow(
        contentRect: CGRect(x: -5000, y: -5000, width: 300, height: 100),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
      )
      window.isReleasedWhenClosed = false
      return window
    }

    /// A key event for `characters` in `window`, or in the fixture's window.
    func key(
      _ type: NSEvent.EventType,
      _ characters: String,
      modifiers: NSEvent.ModifierFlags = [],
      isRepeat: Bool = false,
      in window: NSWindow? = nil
    ) throws -> NSEvent {
      try #require(
        NSEvent.keyEvent(
          with: type,
          location: .zero,
          modifierFlags: modifiers,
          timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: (window ?? self.window).windowNumber,
          context: nil,
          characters: characters,
          charactersIgnoringModifiers: characters,
          isARepeat: isRepeat,
          keyCode: 46
        )
      )
    }

    func close() {
      view.removeFromSuperview()
      window.close()
    }
  }

  @Test func `A key-down holds, its repeats change nothing, and the key-up releases`() throws {
    let fixture = Fixture()
    defer { fixture.close() }

    #expect(fixture.view.consumes(try fixture.key(.keyDown, "m")))
    #expect(fixture.holds == [true])
    #expect(fixture.view.consumes(try fixture.key(.keyDown, "m", isRepeat: true)))
    #expect(fixture.holds == [true])
    #expect(fixture.view.consumes(try fixture.key(.keyUp, "m")))
    #expect(fixture.holds == [true, false])
  }

  @Test func `The key holds with Caps Lock on`() throws {
    let fixture = Fixture()
    defer { fixture.close() }

    #expect(fixture.view.consumes(try fixture.key(.keyDown, "M", modifiers: .capsLock)))
    #expect(fixture.view.consumes(try fixture.key(.keyUp, "M", modifiers: .capsLock)))
    #expect(fixture.holds == [true, false])
  }

  @Test func `Command-M, Shift-M and other keys pass on`() throws {
    let fixture = Fixture()
    defer { fixture.close() }

    #expect(fixture.view.consumes(try fixture.key(.keyDown, "m", modifiers: .command)) == false)
    #expect(fixture.view.consumes(try fixture.key(.keyDown, "M", modifiers: .shift)) == false)
    #expect(fixture.view.consumes(try fixture.key(.keyDown, "n")) == false)
    #expect(fixture.holds.isEmpty)
  }

  @Test func `The key passes on while text is edited, and holds while a slider has focus`() throws {
    let fixture = Fixture()
    defer { fixture.close() }

    let textView = NSTextView(frame: CGRect(x: 0, y: 0, width: 100, height: 20))
    fixture.window.contentView?.addSubview(textView)
    try #require(fixture.window.makeFirstResponder(textView))
    #expect(fixture.view.consumes(try fixture.key(.keyDown, "m")) == false)
    #expect(fixture.holds.isEmpty)

    let slider = AdjustmentSlider.Control(frame: CGRect(x: 0, y: 40, width: 100, height: 20))
    fixture.window.contentView?.addSubview(slider)
    try #require(fixture.window.makeFirstResponder(slider))
    #expect(fixture.view.consumes(try fixture.key(.keyDown, "m")))
    #expect(fixture.holds == [true])
  }

  @Test func `The key-up ends a hold whatever modifier, focus or enabled state it meets`() throws {
    let fixture = Fixture()
    defer { fixture.close() }

    // Command pressed during the hold.
    #expect(fixture.view.consumes(try fixture.key(.keyDown, "m")))
    #expect(fixture.view.consumes(try fixture.key(.keyUp, "m", modifiers: .command)))
    #expect(fixture.holds == [true, false])

    // Text focused during the hold.
    #expect(fixture.view.consumes(try fixture.key(.keyDown, "m")))
    let textView = NSTextView(frame: CGRect(x: 0, y: 0, width: 100, height: 20))
    fixture.window.contentView?.addSubview(textView)
    try #require(fixture.window.makeFirstResponder(textView))
    #expect(fixture.view.consumes(try fixture.key(.keyUp, "m")))
    #expect(fixture.holds == [true, false, true, false])

    // The monitor disabled during the hold.
    try #require(fixture.window.makeFirstResponder(nil))
    #expect(fixture.view.consumes(try fixture.key(.keyDown, "m")))
    fixture.view.isEnabled = false
    #expect(fixture.view.consumes(try fixture.key(.keyUp, "m")))
    #expect(fixture.holds == [true, false, true, false, true, false])

    // Without a hold, the key-up passes on.
    #expect(fixture.view.consumes(try fixture.key(.keyUp, "m")) == false)
  }

  @Test func `Keys of another window, or of a window that is not key, pass on`() throws {
    let fixture = Fixture()
    defer { fixture.close() }
    let other = Fixture.makeWindow()
    defer { other.close() }

    #expect(fixture.view.consumes(try fixture.key(.keyDown, "m", in: other)) == false)

    fixture.window.reportsKey = false
    #expect(fixture.view.consumes(try fixture.key(.keyDown, "m")) == false)
    #expect(fixture.holds.isEmpty)
  }

  @Test func `A disabled monitor passes the key on`() throws {
    let fixture = Fixture()
    defer { fixture.close() }
    fixture.view.isEnabled = false

    #expect(fixture.view.consumes(try fixture.key(.keyDown, "m")) == false)
    #expect(fixture.view.consumes(try fixture.key(.keyUp, "m")) == false)
    #expect(fixture.holds.isEmpty)
  }

  @Test func `Resigning key and leaving the window release the hold`() throws {
    let fixture = Fixture()
    defer { fixture.close() }

    #expect(fixture.view.consumes(try fixture.key(.keyDown, "m")))
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: fixture.window)
    #expect(fixture.holds == [true, false])

    #expect(fixture.view.consumes(try fixture.key(.keyDown, "m")))
    fixture.view.removeFromSuperview()
    #expect(fixture.holds == [true, false, true, false])

    // Out of the window it consumes nothing.
    #expect(fixture.view.consumes(try fixture.key(.keyDown, "m")) == false)
    #expect(fixture.holds == [true, false, true, false])
  }
}

#endif
