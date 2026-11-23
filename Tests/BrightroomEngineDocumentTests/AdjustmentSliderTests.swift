#if os(macOS)

import AppKit
import SwiftUI
import Testing

@testable import BrightroomUI

/// The macOS inspector's slider control in an offscreen window, driven
/// through the methods AppKit calls: how each mouse, key and VoiceOver
/// operation ends, when an update leaves the value alone, and how the
/// window's key and main state colour the fill.
@MainActor
struct AdjustmentSliderTests {

  /// A window that reports key and main as the test sets them, without
  /// being ordered on screen.
  final class StateWindow: NSWindow {

    var reportsKey = false
    var reportsMain = false

    override var isKeyWindow: Bool {
      reportsKey
    }

    override var isMainWindow: Bool {
      reportsMain
    }
  }

  /// A control set up by an `AdjustmentSlider` over -100...100, in a window
  /// that is never ordered on screen, recording what the slider reports.
  @MainActor
  final class Fixture {

    var changes: [Double] = []
    var ends: [Double] = []
    /// Whether AppKit's tracking loop was running at each end.
    var endsWhileTracking: [Bool] = []
    var laterEnds = 0

    let window: StateWindow
    let control = AdjustmentSlider.Control(frame: CGRect(x: 10, y: 10, width: 200, height: 22))

    /// The control's target, held here because a control holds its target
    /// weakly.
    private var coordinator: AdjustmentSlider.Coordinator?

    init(value: Double = 0, neutralValue: Double = 0) {
      _ = NSApplication.shared
      window = StateWindow(
        contentRect: CGRect(x: -5000, y: -5000, width: 300, height: 60),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
      )
      window.isReleasedWhenClosed = false
      window.contentView?.addSubview(control)
      slider(value: value, neutralValue: neutralValue).update(control)
      control.doubleValue = value
    }

    func slider(value: Double, neutralValue: Double = 0, isEnabled: Bool = true) -> AdjustmentSlider {
      AdjustmentSlider(
        value: value,
        range: -100...100,
        neutralValue: neutralValue,
        track: .plain,
        isEnabled: isEnabled,
        accessibilityLabel: "Exposure",
        accessibilityIdentifier: "image-editor.adjust.exposure",
        valueDescription: { "\(Int($0)) percent" },
        onChange: { [weak self] in
          self?.changes.append($0)
        },
        onEnd: { [weak self] in
          guard let self else {
            return
          }
          self.ends.append($0)
          self.endsWhileTracking.append(self.control.isTracking)
        },
        onEndLater: { [weak self] in
          self?.laterEnds += 1
        }
      )
    }

    /// A mouse-down at `x` in the window, level with the control's track.
    func mouseDown(atX x: CGFloat, clickCount: Int) throws -> NSEvent {
      try #require(
        NSEvent.mouseEvent(
          with: .leftMouseDown,
          location: CGPoint(x: x, y: control.frame.midY),
          modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber,
          context: nil,
          eventNumber: 0,
          clickCount: clickCount,
          pressure: 1
        )
      )
    }

    func rightArrowKeyUp() throws -> NSEvent {
      // NSRightArrowFunctionKey
      let rightArrow = "\u{F703}"
      return try #require(
        NSEvent.keyEvent(
          with: .keyUp,
          location: .zero,
          modifierFlags: [.numericPad, .function],
          timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber,
          context: nil,
          characters: rightArrow,
          charactersIgnoringModifiers: rightArrow,
          isARepeat: false,
          keyCode: 124
        )
      )
    }

    /// Command going down, when `flags` holds `.command`, or up.
    func commandChanged(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
      try #require(
        NSEvent.keyEvent(
          with: .flagsChanged,
          location: .zero,
          modifierFlags: flags,
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

    /// The point at the centre of the knob, in the window.
    func knobCenter() throws -> CGPoint {
      let cell = try #require(control.cell as? NSSliderCell)
      let knob = cell.knobRect(flipped: control.isFlipped)
      return control.convert(CGPoint(x: knob.midX, y: knob.midY), to: nil)
    }

    /// Targets the control at a coordinator, as `makeNSView(context:)` does.
    func connectCoordinator() {
      let coordinator = AdjustmentSlider.Coordinator()
      control.target = coordinator
      control.action = #selector(AdjustmentSlider.Coordinator.valueChanged(_:))
      self.coordinator = coordinator
    }

    func close() {
      window.close()
    }
  }

  // MARK: - Mouse

  @Test func `A double-click resets to the neutral value with one preview and one end`() throws {
    let fixture = Fixture(value: 40, neutralValue: 25)
    defer { fixture.close() }

    fixture.control.mouseDown(with: try fixture.mouseDown(atX: 60, clickCount: 2))

    #expect(fixture.control.doubleValue == 25)
    #expect(fixture.changes == [25])
    #expect(fixture.ends == [25])
  }

  @Test func `A click ends once after the tracking loop, and the mouse-up action then ends nothing`() throws {
    let fixture = Fixture()
    defer { fixture.close() }
    fixture.connectCoordinator()

    // On the track, right of the knob.
    fixture.control.mouseDown(with: try fixture.mouseDown(atX: 180, clickCount: 1))

    let clicked = fixture.control.doubleValue.rounded()
    #expect(fixture.ends == [clicked])
    #expect(fixture.endsWhileTracking == [false])

    // AppKit's last action of the gesture previews, and the gesture is over.
    fixture.control.actionDidFire(currentEventType: .leftMouseUp)
    #expect(fixture.changes.last == clicked)
    #expect(fixture.ends == [clicked])
  }

  @Test func `A click on the knob reports nothing, so a double-click on it ends once`() throws {
    let fixture = Fixture(value: 40)
    defer { fixture.close() }
    fixture.connectCoordinator()
    let knobX = try fixture.knobCenter().x

    // AppKit sends an action for the click, with the value it reads back
    // from the knob's position.
    fixture.control.mouseDown(with: try fixture.mouseDown(atX: knobX, clickCount: 1))
    fixture.control.actionDidFire(currentEventType: .leftMouseUp)
    #expect(fixture.control.doubleValue.rounded() == 40)
    #expect(fixture.changes.isEmpty)
    #expect(fixture.ends.isEmpty)

    fixture.control.mouseDown(with: try fixture.mouseDown(atX: knobX, clickCount: 2))
    #expect(fixture.changes == [0])
    #expect(fixture.ends == [0])
  }

  // MARK: - Keyboard

  @Test func `A key step moves by one, or ten with Shift, within the range, and previews each value`() {
    let fixture = Fixture()
    defer { fixture.close() }

    fixture.control.step(by: 1, modifiers: [])
    fixture.control.step(by: -1, modifiers: [])
    fixture.control.step(by: 1, modifiers: .shift)
    #expect(fixture.changes == [1, 0, 10])

    // Arrow keys carry the numeric pad and function flags.
    fixture.control.doubleValue = 95
    fixture.control.step(by: 1, modifiers: [.shift, .numericPad, .function])
    fixture.control.doubleValue = -99
    fixture.control.step(by: -1, modifiers: [.numericPad, .function])
    fixture.control.step(by: -1, modifiers: [])
    #expect(fixture.changes == [1, 0, 10, 100, -100, -100])
    #expect(fixture.ends.isEmpty)
    #expect(fixture.control.isKeyStepping)
  }

  @Test func `The arrow keys step the way they point, mirrored right to left`() {
    let fixture = Fixture()
    defer { fixture.close() }

    fixture.control.moveRight(nil)
    fixture.control.moveUp(nil)
    fixture.control.moveLeft(nil)
    fixture.control.moveDown(nil)
    #expect(fixture.changes == [1, 2, 1, 0])

    // The minimum is at the right end.
    fixture.control.userInterfaceLayoutDirection = .rightToLeft
    fixture.control.moveRight(nil)
    fixture.control.moveLeft(nil)
    fixture.control.moveUp(nil)
    #expect(fixture.changes == [1, 2, 1, 0, -1, 0, 1])
  }

  @Test func `Page Up and Page Down step to the ends of the range, and the key-up ends each`() throws {
    let fixture = Fixture(value: 40)
    defer { fixture.close() }

    fixture.control.pageUp(nil)
    #expect(fixture.changes == [100])
    #expect(fixture.ends.isEmpty)
    fixture.control.keyUp(with: try fixture.rightArrowKeyUp())
    #expect(fixture.ends == [100])

    fixture.control.pageDown(nil)
    fixture.control.keyUp(with: try fixture.rightArrowKeyUp())
    #expect(fixture.changes == [100, -100])
    #expect(fixture.ends == [100, -100])
  }

  @Test func `The key-up ends a key step once`() throws {
    let fixture = Fixture()
    defer { fixture.close() }

    fixture.control.step(by: 1, modifiers: [])
    fixture.control.step(by: 1, modifiers: [])
    fixture.control.keyUp(with: try fixture.rightArrowKeyUp())
    fixture.control.keyUp(with: try fixture.rightArrowKeyUp())

    #expect(fixture.changes == [1, 2])
    #expect(fixture.ends == [2])
    #expect(fixture.control.isKeyStepping == false)
  }

  @Test func `Focus leaving during a key step ends it on the next turn, without a value`() async throws {
    let fixture = Fixture()
    defer { fixture.close() }

    fixture.control.step(by: 1, modifiers: [])
    #expect(fixture.control.resignFirstResponder())
    #expect(fixture.laterEnds == 0)

    for _ in 0..<100 where fixture.laterEnds == 0 {
      await Task.yield()
    }
    #expect(fixture.laterEnds == 1)
    #expect(fixture.ends.isEmpty)

    // The step is over: its key-up ends nothing, and focus leaving again
    // ends nothing either.
    fixture.control.keyUp(with: try fixture.rightArrowKeyUp())
    #expect(fixture.control.resignFirstResponder())
    for _ in 0..<10 {
      await Task.yield()
    }
    #expect(fixture.ends.isEmpty)
    #expect(fixture.laterEnds == 1)
  }

  @Test func `Leaving the window during a key step ends it on the next turn, without a value`() async throws {
    let fixture = Fixture()
    defer { fixture.close() }
    _ = fixture.window.makeFirstResponder(fixture.control)

    fixture.control.step(by: 1, modifiers: [])
    // AppKit does not ask a first responder that leaves the window to
    // resign.
    fixture.control.removeFromSuperview()
    #expect(fixture.control.isKeyStepping == false)
    #expect(fixture.laterEnds == 0)

    for _ in 0..<100 where fixture.laterEnds == 0 {
      await Task.yield()
    }
    #expect(fixture.laterEnds == 1)
    #expect(fixture.ends.isEmpty)
  }

  @Test func `The window resigning key during a key step ends it on the next turn, without a value`() async throws {
    let fixture = Fixture()
    defer { fixture.close() }
    fixture.window.reportsKey = true

    // The arrow is still down when another window or app becomes key, which
    // then receives its key-up.
    fixture.control.step(by: 1, modifiers: [])
    fixture.window.reportsKey = false
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: fixture.window)
    #expect(fixture.control.isKeyStepping == false)
    #expect(fixture.laterEnds == 0)

    for _ in 0..<100 where fixture.laterEnds == 0 {
      await Task.yield()
    }
    #expect(fixture.laterEnds == 1)
    #expect(fixture.ends.isEmpty)

    // Resigning key again ends nothing more.
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: fixture.window)
    for _ in 0..<10 {
      await Task.yield()
    }
    #expect(fixture.laterEnds == 1)
    #expect(fixture.ends.isEmpty)
  }

  @Test func `A key pressed with Command steps nothing, and Command going down ends a key step`() throws {
    let fixture = Fixture()
    defer { fixture.close() }

    // AppKit delivers no key-up while Command is down.
    fixture.control.step(by: 1, modifiers: [.command, .numericPad, .function])
    fixture.control.keyStep(to: 100, modifiers: .command)
    #expect(fixture.changes.isEmpty)
    #expect(fixture.control.isKeyStepping == false)

    // An arrow held when Command goes down.
    fixture.control.step(by: 1, modifiers: [.numericPad, .function])
    fixture.control.flagsChanged(with: try fixture.commandChanged(.command))
    #expect(fixture.ends == [1])
    #expect(fixture.control.isKeyStepping == false)

    // Neither Command going up nor the arrow's key-up ends anything more.
    fixture.control.flagsChanged(with: try fixture.commandChanged([]))
    fixture.control.keyUp(with: try fixture.rightArrowKeyUp())
    #expect(fixture.changes == [1])
    #expect(fixture.ends == [1])
  }

  @Test func `A key step's end returns the knob to what the editor shows`() async throws {
    let fixture = Fixture()
    defer { fixture.close() }

    // The editor shows the step's value: the knob stays.
    fixture.control.step(by: 1, modifiers: [])
    fixture.slider(value: 1).update(fixture.control)
    fixture.control.keyUp(with: try fixture.rightArrowKeyUp())
    #expect(fixture.control.doubleValue == 1)

    // The editor ended the operation first and takes nothing from the rest
    // of the step, so no update follows its end.
    fixture.control.step(by: 1, modifiers: [])
    fixture.slider(value: -50).update(fixture.control)
    fixture.control.step(by: 1, modifiers: [])
    #expect(fixture.control.doubleValue == 3)
    fixture.control.keyUp(with: try fixture.rightArrowKeyUp())
    #expect(fixture.control.doubleValue == -50)

    // The same when focus cuts the step short.
    fixture.control.step(by: 1, modifiers: [])
    fixture.slider(value: 20).update(fixture.control)
    #expect(fixture.control.resignFirstResponder())
    #expect(fixture.control.doubleValue == 20)
    for _ in 0..<100 where fixture.laterEnds == 0 {
      await Task.yield()
    }
    #expect(fixture.ends == [1, 3])
    #expect(fixture.laterEnds == 1)
  }

  // MARK: - VoiceOver

  @Test func `Each VoiceOver step moves by five, previews and ends at once`() throws {
    let fixture = Fixture()
    defer { fixture.close() }
    fixture.connectCoordinator()

    // VoiceOver addresses the cell; the control is not an accessibility
    // element.
    let cell = try #require(fixture.control.cell)
    #expect(cell.isAccessibilityElement())
    #expect(fixture.control.isAccessibilityElement() == false)

    _ = cell.accessibilityPerformIncrement()
    #expect(fixture.changes == [5])
    #expect(fixture.ends == [5])

    _ = cell.accessibilityPerformDecrement()
    #expect(fixture.control.accessibilityPerformDecrement())
    #expect(fixture.changes == [5, 0, -5])
    #expect(fixture.ends == [5, 0, -5])

    fixture.control.doubleValue = 98
    _ = cell.accessibilityPerformIncrement()
    #expect(fixture.control.doubleValue == 100)
    #expect(fixture.ends == [5, 0, -5, 100])
  }

  @Test func `VoiceOver reads the value through the value description`() {
    let fixture = Fixture(value: 12)
    defer { fixture.close() }

    #expect(fixture.control.accessibilityValueDescription() == "12 percent")
  }

  // MARK: - Updates

  @Test func `An update leaves the value alone while a key steps or the mouse tracks`() throws {
    let fixture = Fixture()
    defer { fixture.close() }
    let slider = fixture.slider(value: -50)

    // A key step keeps its value until its key-up.
    fixture.control.step(by: 1, modifiers: [])
    slider.update(fixture.control)
    #expect(fixture.control.doubleValue == 1)
    fixture.control.keyUp(with: try fixture.rightArrowKeyUp())
    slider.update(fixture.control)
    #expect(fixture.control.doubleValue == -50)

    // An update made from an action inside the tracking loop keeps the
    // value the click moved to.
    fixture.connectCoordinator()
    var keptWhileTracking: [Bool] = []
    fixture.control.onChange = { [weak control = fixture.control] _ in
      guard let control, control.isTracking else {
        return
      }
      let shown = control.doubleValue
      slider.update(control)
      keptWhileTracking.append(control.doubleValue == shown)
    }
    fixture.control.mouseDown(with: try fixture.mouseDown(atX: 180, clickCount: 1))
    try #require(keptWhileTracking.isEmpty == false, "AppKit sent no action while tracking")
    #expect(keptWhileTracking.allSatisfy { $0 })
    #expect(fixture.control.doubleValue > -50)
  }

  @Test func `An update brings the range, reset value, track, enabled state and accessibility up to date`() {
    let fixture = Fixture()
    defer { fixture.close() }

    AdjustmentSlider(
      value: 30,
      range: 0...100,
      neutralValue: 50,
      track: .temperature,
      isEnabled: false,
      accessibilityLabel: "Blending",
      accessibilityIdentifier: "image-editor.grading.blending",
      valueDescription: { "\(Int($0)) percent" },
      onChange: { _ in },
      onEnd: { _ in },
      onEndLater: {}
    )
    .update(fixture.control)

    let cell = fixture.control.cell as? AdjustmentSlider.Cell
    #expect(fixture.control.minValue == 0)
    #expect(fixture.control.maxValue == 100)
    #expect(fixture.control.doubleValue == 30)
    #expect(fixture.control.resetValue == 50)
    #expect(cell?.track == .temperature)
    #expect(cell?.neutral == 50)
    #expect(fixture.control.isEnabled == false)
    #expect(fixture.control.accessibilityLabel() == "Blending")
    #expect(fixture.control.accessibilityIdentifier() == "image-editor.grading.blending")
  }

  @Test func `A disabled environment keeps an enabled slider disabled`() {
    let fixture = Fixture()
    defer { fixture.close() }
    var disabled = EnvironmentValues()
    disabled.isEnabled = false

    fixture.slider(value: 0).update(fixture.control, in: disabled)
    #expect(fixture.control.isEnabled == false)

    fixture.slider(value: 10).update(fixture.control, in: disabled)
    #expect(fixture.control.isEnabled == false)

    fixture.slider(value: 10).update(fixture.control, in: .init())
    #expect(fixture.control.isEnabled)
  }

  @Test func `A disabled slider ignores double-clicks, key steps and VoiceOver steps`() throws {
    let fixture = Fixture(value: 40)
    defer { fixture.close() }
    fixture.connectCoordinator()
    fixture.slider(value: 40, isEnabled: false).update(fixture.control)

    fixture.control.mouseDown(with: try fixture.mouseDown(atX: 60, clickCount: 2))
    fixture.control.step(by: 1, modifiers: [])
    fixture.control.pageUp(nil)
    #expect(fixture.control.accessibilityPerformIncrement() == false)
    _ = fixture.control.cell?.accessibilityPerformIncrement()

    #expect(fixture.control.doubleValue == 40)
    #expect(fixture.control.isKeyStepping == false)
    #expect(fixture.changes.isEmpty)
    #expect(fixture.ends.isEmpty)
  }

  // MARK: - Window state

  @Test func `The fill takes the accent color while the window is key or main, and redraws as either changes`() throws {
    let fixture = Fixture()
    defer { fixture.close() }
    let cell = try #require(fixture.control.cell as? AdjustmentSlider.Cell)

    #expect(cell.fillColor == .secondaryLabelColor)

    // Sets the window's state, posts `name` as AppKit does, and returns
    // whether the slider then needs to redraw.
    func post(_ name: NSNotification.Name, key: Bool, main: Bool) -> Bool {
      fixture.window.reportsKey = key
      fixture.window.reportsMain = main
      fixture.control.needsDisplay = false
      NotificationCenter.default.post(name: name, object: fixture.window)
      return fixture.control.needsDisplay
    }

    #expect(post(NSWindow.didBecomeKeyNotification, key: true, main: true))
    #expect(cell.fillColor == .controlAccentColor)

    // A panel becomes key, and the window stays main.
    #expect(post(NSWindow.didResignKeyNotification, key: false, main: true))
    #expect(cell.fillColor == .controlAccentColor)

    #expect(post(NSWindow.didResignMainNotification, key: false, main: false))
    #expect(cell.fillColor == .secondaryLabelColor)

    #expect(post(NSWindow.didBecomeMainNotification, key: false, main: true))
    #expect(cell.fillColor == .controlAccentColor)

    // Disabled, whatever the window.
    fixture.slider(value: 0, isEnabled: false).update(fixture.control)
    #expect(cell.fillColor == .tertiaryLabelColor)
  }
}

#endif
