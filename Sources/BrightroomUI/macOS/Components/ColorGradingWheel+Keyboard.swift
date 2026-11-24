#if os(macOS)
import AppKit
import BrightroomParametric
import SwiftUI

extension ColorGradingWheel {

  /// The wheel's keyboard on the Mac: a view over the wheel that takes focus
  /// as a control does, through Full Keyboard Access, and draws the focus
  /// ring around the wheel.
  ///
  /// While it has focus, the Left and Right arrows turn the hue by 1 degree
  /// and Up and Down move the saturation by 1, ten times as far with Shift.
  /// Each press, held or not, previews its steps with `onChange` and ends one
  /// operation with `onEnd` at its key-up, or when Command goes down before
  /// it. A step that focus or the window leaves, or that the window resigning
  /// key cuts short, ends through `onEndLater` instead. It is AppKit for
  /// those ends: AppKit reports Command going down and the window resigning
  /// key, which SwiftUI's key presses do not.
  struct Keyboard: NSViewRepresentable {

    let correction: ColorGradingFeature.Correction
    let onChange: (ColorGradingFeature.Correction) -> Void
    let onEnd: (ColorGradingFeature.Correction) -> Void
    /// Ends a key step that focus or the window left on the next main-actor
    /// turn, so that nothing is written inside a view update. It carries no
    /// value.
    let onEndLater: () -> Void

    func makeNSView(context: Context) -> Responder {
      let responder = Responder()
      updateNSView(responder, context: context)
      return responder
    }

    /// The responder is enabled while the environment is, so a disabled
    /// wheel takes no focus and steps nothing.
    func updateNSView(_ responder: Responder, context: Context) {
      responder.shownCorrection = correction
      responder.isEnabled = context.environment.isEnabled
      responder.onChange = onChange
      responder.onEnd = onEnd
      responder.onEndLater = onEndLater
    }

    /// The view that takes focus and the arrow keys. It takes no clicks,
    /// which go to the wheel under it, and VoiceOver reads the wheel's
    /// sliders instead of it.
    final class Responder: NSView {

      private static let keyStep = 1.0
      private static let largeKeyStep = 10.0

      /// The correction of the latest update: what the wheel shows.
      var shownCorrection = ColorGradingFeature.Correction()

      var isEnabled = true

      var onChange: ((ColorGradingFeature.Correction) -> Void)?
      var onEnd: ((ColorGradingFeature.Correction) -> Void)?
      var onEndLater: (() -> Void)?

      /// The correction of the key step that waits for its key-up; nil while
      /// none does.
      private var steppedCorrection: ColorGradingFeature.Correction?

      /// Observes the window resigning key, while the view is in a window.
      private var windowObserver: (any NSObjectProtocol)?

      isolated deinit {
        stopObservingWindow()
      }

      override var acceptsFirstResponder: Bool {
        isEnabled
      }

      /// In the window's key view loop only under Full Keyboard Access, as a
      /// control is.
      override var canBecomeKeyView: Bool {
        NSApp.isFullKeyboardAccessEnabled && super.canBecomeKeyView
      }

      override func hitTest(_ point: NSPoint) -> NSView? {
        nil
      }

      override func isAccessibilityElement() -> Bool {
        false
      }

      // MARK: - Focus ring

      override var focusRingMaskBounds: NSRect {
        wheelRect
      }

      override func drawFocusRingMask() {
        NSBezierPath(ovalIn: wheelRect).fill()
      }

      override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        noteFocusRingMaskChanged()
      }

      /// The wheel's circle: the largest the bounds hold, at their center.
      private var wheelRect: NSRect {
        let side = min(bounds.width, bounds.height)
        return NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
      }

      // MARK: - Keyboard

      override func keyDown(with event: NSEvent) {
        guard let direction = Self.direction(of: event) else {
          super.keyDown(with: event)
          return
        }
        step(direction, modifiers: event.modifierFlags)
      }

      /// Steps the correction toward `direction`, ten times as far with
      /// Shift, from the step in progress or else from the shown correction,
      /// and previews it. The key-up ends the operation. A key pressed with
      /// Command steps nothing: AppKit delivers no key-up while Command is
      /// down, so nothing would end the step.
      func step(_ direction: MoveCommandDirection, modifiers: NSEvent.ModifierFlags) {
        guard isEnabled, modifiers.contains(.command) == false else {
          return
        }

        let amount = if modifiers.contains(.shift) { Self.largeKeyStep } else { Self.keyStep }
        let next = Self.stepped(steppedCorrection ?? shownCorrection, toward: direction, by: amount)
        steppedCorrection = next
        onChange?(next)
      }

      override func keyUp(with event: NSEvent) {
        super.keyUp(with: event)
        endKeyStep()
      }

      /// Command going down ends a key step: AppKit delivers no key-up while
      /// Command is down, so the held key's key-up would never arrive.
      override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        if event.modifierFlags.contains(.command) {
          endKeyStep()
        }
      }

      override func resignFirstResponder() -> Bool {
        let resigns = super.resignFirstResponder()
        if resigns {
          endKeyStepLater()
        }
        return resigns
      }

      /// AppKit does not ask a first responder that leaves the window to
      /// resign, so leaving the window ends a key step as losing focus does.
      override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow !== window {
          endKeyStepLater()
        }
      }

      /// Ends the key step in progress with one `onEnd`; does nothing when
      /// none is.
      private func endKeyStep() {
        guard let steppedCorrection else {
          return
        }

        self.steppedCorrection = nil
        onEnd?(steppedCorrection)
      }

      /// Ends the key step in progress through `onEndLater` on the next turn;
      /// does nothing when none is. Focus can leave, and SwiftUI can remove
      /// the wheel, inside a view update, where nothing may be written.
      private func endKeyStepLater() {
        guard steppedCorrection != nil else {
          return
        }

        steppedCorrection = nil
        let onEndLater = onEndLater
        Task { @MainActor in
          onEndLater?()
        }
      }

      // MARK: - Window

      /// The window resigning key ends a key step, as losing focus does,
      /// because the key-up then goes elsewhere.
      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObservingWindow()
        guard let window else {
          return
        }

        windowObserver = NotificationCenter.default.addObserver(
          forName: NSWindow.didResignKeyNotification,
          object: window,
          queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated {
            self?.endKeyStepLater()
          }
        }
      }

      private func stopObservingWindow() {
        if let windowObserver {
          NotificationCenter.default.removeObserver(windowObserver)
        }
        windowObserver = nil
      }

      // MARK: - Steps

      /// `correction` stepped by `amount` toward `direction`: Left and Right
      /// turn the hue around the wheel, and Up and Down move the saturation,
      /// which stops at its ends.
      static func stepped(
        _ correction: ColorGradingFeature.Correction,
        toward direction: MoveCommandDirection,
        by amount: Double
      ) -> ColorGradingFeature.Correction {
        var next = correction
        switch direction {
        case .left:
          next.hue = wrappedHue(correction.hue - amount)
        case .right:
          next.hue = wrappedHue(correction.hue + amount)
        case .up:
          next.saturation = correction.saturation + amount
        case .down:
          next.saturation = correction.saturation - amount
        @unknown default:
          break
        }
        return next
      }

      /// `hue` within one turn of the wheel, 0 up to 360.
      private static func wrappedHue(_ hue: Double) -> Double {
        (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
      }

      /// The arrow `event` presses; nil for any other key.
      private static func direction(of event: NSEvent) -> MoveCommandDirection? {
        guard let key = event.specialKey else {
          return nil
        }

        return switch key {
        case .leftArrow: .left
        case .rightArrow: .right
        case .upArrow: .up
        case .downArrow: .down
        default: nil
        }
      }
    }
  }
}
#endif
