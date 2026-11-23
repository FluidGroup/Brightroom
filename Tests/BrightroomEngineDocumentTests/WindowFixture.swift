#if os(macOS)

import AppKit
import Testing

@testable import BrightroomUI

/// A SwiftUI view hosted in an AppKit window for a test, and what the window
/// tests do with it: lay the window out until something holds, find the
/// editor's views, let the canvas and the inspector settle, and deliver keys
/// and clicks to the window in-process, as the keyboard and the mouse would
/// while it is key. Nothing is posted to the system, and the window never
/// shows on a screen.
@MainActor
protocol WindowFixture {

  var window: NSWindow { get }

  /// The window's content view, which hosts the test's root view.
  var hostingView: NSView { get }
}

extension WindowFixture {

  /// A window of `size` that shows `contentView` and never shows on a
  /// screen: titled and never ordered in, or, with `receivesClicks`,
  /// borderless and ordered in far off every screen, because SwiftUI handles
  /// clicks only in a window that is ordered in, and AppKit moves a titled
  /// window onto a screen.
  static func makeWindow(showing contentView: NSView, size: CGSize, receivesClicks: Bool) -> NSWindow {
    _ = NSApplication.shared
    let window = if receivesClicks {
      NSWindow(
        contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
      )
    } else {
      NSWindow(
        contentRect: CGRect(origin: .zero, size: size),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
      )
    }
    window.isReleasedWhenClosed = false
    window.contentView = contentView
    if receivesClicks {
      window.orderFrontRegardless()
    }
    return window
  }

  func close() {
    window.orderOut(nil)
    window.contentView = nil
    window.close()
  }

  // MARK: - Views

  /// The canvas the editor shows, if one is mounted.
  var canvas: EditingCanvasView? {
    Self.first(EditingCanvasView.self, in: hostingView)
  }

  /// The filter strip's scroll view: SwiftUI backs a horizontal
  /// `ScrollView` with an `NSScrollView` that scrolls horizontally, and the
  /// inspector's scrolls vertically.
  var filterStrip: NSScrollView? {
    Self.all(NSScrollView.self, in: hostingView).first { $0.hasHorizontalScroller }
  }

  /// The inspector's sliders, by accessibility identifier.
  var sliders: [String: AdjustmentSlider.Control] {
    Dictionary(
      Self.all(AdjustmentSlider.Control.self, in: hostingView).map { ($0.accessibilityIdentifier(), $0) },
      uniquingKeysWith: { _, last in last }
    )
  }

  /// The grading wheels' keyboard views, each over its wheel, from the
  /// leading edge.
  var wheelKeyboards: [ColorGradingWheel.Keyboard.Responder] {
    Self.all(ColorGradingWheel.Keyboard.Responder.self, in: hostingView).sorted {
      $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX
    }
  }

  /// The views of `type` in the tree of `view`, `view` included, depth
  /// first.
  static func all<View: NSView>(_ type: View.Type, in view: NSView) -> [View] {
    var matches: [View] = []
    if let match = view as? View {
      matches.append(match)
    }
    for subview in view.subviews {
      matches += all(type, in: subview)
    }
    return matches
  }

  /// The first of `all(_:in:)`.
  static func first<View: NSView>(_ type: View.Type, in view: NSView) -> View? {
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

  // MARK: - Waiting

  /// Lays the window out until `condition` holds, for five seconds at most.
  func wait(
    until condition: () -> Bool,
    _ comment: Comment,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async throws {
    for _ in 0..<250 {
      hostingView.layoutSubtreeIfNeeded()
      if condition() {
        return
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record(comment, sourceLocation: sourceLocation)
    throw CancellationError()
  }

  /// Lays the window out for ten ticks, for changes with nothing in AppKit
  /// to wait for.
  func settle() async throws {
    for _ in 0..<10 {
      hostingView.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  /// The inspector's slider with `identifier`, once the inspector shows it.
  func slider(
    _ identifier: String,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async throws -> AdjustmentSlider.Control {
    try await wait(
      until: { sliders[identifier] != nil },
      "The inspector shows no slider \(identifier)",
      sourceLocation: sourceLocation
    )
    return try #require(sliders[identifier], sourceLocation: sourceLocation)
  }

  /// The canvas once it has built its render images and drawn a frame.
  func drawnCanvas(sourceLocation: SourceLocation = #_sourceLocation) async throws -> EditingCanvasView {
    try await wait(
      until: {
        canvas?.surface.canvasView?.hasRenderImages == true
          && canvas?.surface.displayedViewport != nil
      },
      "The editor did not draw its canvas",
      sourceLocation: sourceLocation
    )
    return try #require(canvas, sourceLocation: sourceLocation)
  }

  /// Ticks `canvas` until its zoom and pan stop moving, for five seconds at
  /// most: a zoom command animates unless Reduce Motion is on.
  func settleMotion(of canvas: EditingCanvasView) async throws {
    for _ in 0..<250 where canvas.navigation.isMoving {
      canvas.drawViewportFrame()
      try await Task.sleep(for: .milliseconds(20))
    }
    try #require(canvas.navigation.isMoving == false, "The canvas kept moving")
  }

  /// Lays the window out while the inspector finishes showing or hiding,
  /// which it animates.
  func settleInspector() async throws {
    let end = ContinuousClock.now + .milliseconds(800)
    while ContinuousClock.now < end {
      hostingView.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  // MARK: - Keys and clicks

  /// Delivers a key-down to the window's key equivalents, as the keyboard
  /// would while the window is key; returns whether one took it. AppKit
  /// offers the menu bar only a key the window does not take.
  func pressKeyEquivalent(
    _ characters: String,
    modifiers: NSEvent.ModifierFlags = [],
    keyCode: UInt16
  ) throws -> Bool {
    let event = try #require(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
      )
    )
    return window.performKeyEquivalent(with: event)
  }

  /// Presses and releases the arrow `key` in the window, as the keyboard
  /// would while the window is key.
  func press(_ key: NSEvent.SpecialKey) throws {
    for type in [NSEvent.EventType.keyDown, .keyUp] {
      window.sendEvent(try arrowKeyEvent(type, key))
    }
  }

  /// A right-arrow key-up in the window.
  func keyUp() throws -> NSEvent {
    try arrowKeyEvent(.keyUp, .rightArrow)
  }

  /// Clicks the window at `point` (window coordinates), as the mouse
  /// would.
  func click(at point: CGPoint) throws {
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      try mouse(type, at: point)
    }
  }

  /// Sends the window a mouse event at `point` (window coordinates), as the
  /// mouse would.
  func mouse(_ type: NSEvent.EventType, at point: CGPoint, clickCount: Int = 1) throws {
    let event = try #require(
      NSEvent.mouseEvent(
        with: type,
        location: point,
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

  /// A key-down or key-up of the arrow `key` in the window, as the keyboard
  /// makes one.
  private func arrowKeyEvent(_ type: NSEvent.EventType, _ key: NSEvent.SpecialKey) throws -> NSEvent {
    // kVK_LeftArrow, kVK_RightArrow, kVK_DownArrow and kVK_UpArrow.
    let keyCodes: [NSEvent.SpecialKey: UInt16] = [.leftArrow: 123, .rightArrow: 124, .downArrow: 125, .upArrow: 126]
    let keyCode = try #require(keyCodes[key], "Not an arrow key: \(key.rawValue)")
    let characters = String(Character(try #require(Unicode.Scalar(UInt32(key.rawValue)))))
    return try #require(
      NSEvent.keyEvent(
        with: type,
        location: .zero,
        modifierFlags: [.numericPad, .function],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
      )
    )
  }
}

/// Whether a display can draw. The inspector animates as it shows and
/// hides, and that animation does not run while no display can draw: while
/// the display sleeps, or on a Mac without one.
func hasActiveDisplay() -> Bool {
  var count: UInt32 = 0
  return CGGetActiveDisplayList(0, nil, &count) == .success && count > 0
}

#endif
