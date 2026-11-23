#if os(macOS)
import AppKit
import SwiftUI

/// Reports a key held in the view's window: `onHold(true)` when the key goes
/// down, and `onHold(false)` when the hold ends, at the key-up, when the
/// window resigns key, or when the view leaves the window.
///
/// An AppKit local event monitor watches the window's keys, so the hold works
/// whatever has focus, a slider included. While enabled, it consumes the key,
/// plain or with Caps Lock, when the window is key and no text is being
/// edited (the first responder is not an `NSText`); with any other modifier
/// the key passes on, so Command-M still minimizes. A host's own unmodified
/// shortcut for the key in that window does not run then.
struct HoldKeyMonitor: NSViewRepresentable {

  /// The held key, as a lowercase character.
  let key: String
  let isEnabled: Bool
  let onHold: (Bool) -> Void

  func makeNSView(context: Context) -> EventView {
    let view = EventView()
    updateNSView(view, context: context)
    return view
  }

  func updateNSView(_ view: EventView, context: Context) {
    view.key = key
    view.isEnabled = isEnabled
    view.onHold = onHold
  }

  /// Watches its window's keys while it is in a window. It takes no clicks.
  final class EventView: NSView {

    var key = ""
    var isEnabled = false
    var onHold: ((Bool) -> Void)?

    private var isHolding = false
    private var monitor: Any?
    private var resignKeyObserver: (any NSObjectProtocol)?

    isolated deinit {
      stopWatching()
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stopWatching()
      guard let window else {
        return
      }

      monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
        // Local monitors run on the main thread. `NSEvent` is not Sendable,
        // so the event stays inside the main-actor closure and only the
        // decision comes out of it.
        let consumed = MainActor.assumeIsolated {
          self?.consumes(event) ?? false
        }
        if consumed {
          return nil
        }
        return event
      }
      resignKeyObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didResignKeyNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.setHolding(false)
        }
      }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
      nil
    }

    /// Whether the monitor consumes `event`. A consumed key-down that is not
    /// a repeat starts the hold. The key's key-up ends a hold and is consumed
    /// whatever modifier, focus or enabled state it meets.
    func consumes(_ event: NSEvent) -> Bool {
      guard
        event.type == .keyDown || event.type == .keyUp,
        let window,
        event.window === window,
        event.charactersIgnoringModifiers?.lowercased() == key
      else {
        return false
      }

      // A modifier pressed during the hold, such as Command for Command-Z,
      // would otherwise leave it held.
      if event.type == .keyUp, isHolding {
        setHolding(false)
        return true
      }

      guard
        isEnabled,
        window.isKeyWindow,
        event.modifierFlags
          .intersection(.deviceIndependentFlagsMask)
          .subtracting([.capsLock, .numericPad, .function])
          .isEmpty,
        (window.firstResponder is NSText) == false
      else {
        return false
      }

      if event.type == .keyDown, event.isARepeat == false {
        setHolding(true)
      }
      return true
    }

    /// Removes the monitor and the observer, and ends the hold.
    private func stopWatching() {
      if let monitor {
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
      }
      if let resignKeyObserver {
        NotificationCenter.default.removeObserver(resignKeyObserver)
        self.resignKeyObserver = nil
      }
      setHolding(false)
    }

    /// Calls `onHold` once per change.
    private func setHolding(_ holding: Bool) {
      guard isHolding != holding else {
        return
      }

      isHolding = holding
      onHold?(holding)
    }
  }
}
#endif
