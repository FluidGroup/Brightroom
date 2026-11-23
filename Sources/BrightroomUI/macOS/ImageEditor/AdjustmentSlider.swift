#if os(macOS)
import AppKit
import SwiftUI

/// The macOS inspector's slider: an `NSSlider` that keeps the system knob
/// over a thin bar drawn for its track.
///
/// `onChange` previews each value in progress, and every operation ends with
/// one `onEnd`: a drag or a click at the mouse-up, a press or a held arrow,
/// Page Up or Page Down key at the key-up, or when Command goes down before
/// it, a double-click (a reset to `neutralValue`) at once, and each VoiceOver
/// step at once. A click that leaves the value as it is, such as one on the
/// knob, reports nothing, so a double-click on the knob ends once. A key
/// pressed with Command steps nothing, because AppKit delivers no key-up while
/// Command is down. A key step that focus or the window leaves, or that the
/// window resigning key cuts short, ends through `onEndLater` instead.
/// Reported values are whole numbers.
struct AdjustmentSlider: NSViewRepresentable {

  let value: Double
  let range: ClosedRange<Double>
  /// The value a double-click resets to, and where a plain track's fill
  /// starts.
  let neutralValue: Double
  let track: ImageEditor.AdjustmentSection.Track
  let isEnabled: Bool
  let accessibilityLabel: String
  let accessibilityIdentifier: String
  /// VoiceOver's reading of a value, such as "12 percent".
  let valueDescription: (Double) -> String
  /// Previews a value in progress.
  let onChange: (Double) -> Void
  /// Ends an operation with its value.
  let onEnd: (Double) -> Void
  /// Ends a key step that focus or the window left, or that the window
  /// resigning key cut short, on the next main-actor turn, so that nothing
  /// is written inside a view update. It carries no value.
  let onEndLater: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> Control {
    let control = Control()
    control.target = context.coordinator
    control.action = #selector(Coordinator.valueChanged(_:))
    update(control, in: context.environment)
    control.doubleValue = value
    return control
  }

  func updateNSView(_ control: Control, context: Context) {
    update(control, in: context.environment)
  }

  /// Brings `control` up to date, assigning only what changed. It is enabled
  /// while both `isEnabled` and `environment` allow it, so a disabled
  /// ancestor keeps it disabled. The value is left alone while the mouse
  /// tracks or a key steps, and while it is within rounding of `value`.
  func update(_ control: Control, in environment: EnvironmentValues = .init()) {
    control.shownValue = value
    control.onChange = onChange
    control.onEnd = onEnd
    control.onEndLater = onEndLater
    control.valueDescription = valueDescription

    if control.minValue != range.lowerBound {
      control.minValue = range.lowerBound
    }
    if control.maxValue != range.upperBound {
      control.maxValue = range.upperBound
    }
    if control.resetValue != neutralValue {
      control.resetValue = neutralValue
    }
    if let cell = control.cell as? Cell, cell.track != track || cell.neutral != neutralValue {
      cell.track = track
      cell.neutral = neutralValue
      control.needsDisplay = true
    }
    let isEnabled = isEnabled && environment.isEnabled
    if control.isEnabled != isEnabled {
      control.isEnabled = isEnabled
    }
    if control.accessibilityLabel() != accessibilityLabel {
      control.setAccessibilityLabel(accessibilityLabel)
    }
    if control.accessibilityIdentifier() != accessibilityIdentifier {
      control.setAccessibilityIdentifier(accessibilityIdentifier)
    }

    if control.isTracking == false, control.isKeyStepping == false, abs(control.doubleValue - value) >= 0.5 {
      control.doubleValue = value
    }
  }

  /// The slider. It ends its operations itself, at the mouse-up, the key-up,
  /// a double-click and each VoiceOver step, and it ignores input while
  /// disabled, as `NSSlider` does.
  final class Control: NSSlider {

    static let keyStep = 1.0
    static let largeKeyStep = 10.0
    static let accessibilityStep = 5.0

    /// The value a double-click resets to. It is not called `neutralValue`,
    /// a name `NSSlider` uses from macOS 26.
    var resetValue = 0.0

    /// The value of the latest update: what the editor shows.
    var shownValue = 0.0

    var onChange: ((Double) -> Void)?
    var onEnd: ((Double) -> Void)?
    var onEndLater: (() -> Void)?
    var valueDescription: ((Double) -> String)?

    /// Whether AppKit's mouse tracking loop is running.
    private(set) var isTracking = false

    /// Whether a key step waits for its key-up.
    private(set) var isKeyStepping = false

    /// Whether a mouse gesture has begun and not yet ended with `onEnd`.
    private var isGestureOpen = false

    /// The value, rounded, when the latest mouse gesture began.
    private var gestureStartValue = 0.0

    /// Whether the latest mouse gesture has moved the value from
    /// `gestureStartValue`; true until the first gesture.
    private var hasGestureMoved = true

    /// Observers of the window's key and main state, while the slider is in
    /// a window.
    private var windowObservers: [any NSObjectProtocol] = []

    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      // The cell first: the property below is stored in it.
      cell = Cell()
      isContinuous = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
      stopObservingWindow()
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
      guard isEnabled else {
        super.mouseDown(with: event)
        return
      }

      if event.clickCount >= 2 {
        doubleValue = resetValue
        onChange?(resetValue)
        onEnd?(resetValue)
        return
      }

      isGestureOpen = true
      gestureStartValue = doubleValue.rounded()
      hasGestureMoved = false
      isTracking = true
      // AppKit's tracking loop returns after the mouse-up; outside a running
      // app it returns at once.
      super.mouseDown(with: event)
      isTracking = false
      endGesture()
    }

    /// Previews the value, rounded, once the gesture has moved it, so a click
    /// that moves nothing previews nothing. At a mouse-up, AppKit's last
    /// action of a gesture, it also ends the gesture.
    func actionDidFire(currentEventType: NSEvent.EventType?) {
      let value = doubleValue.rounded()
      hasGestureMoved = hasGestureMoved || value != gestureStartValue
      if hasGestureMoved {
        onChange?(value)
      }
      if currentEventType == .leftMouseUp {
        endGesture()
      }
    }

    /// Ends the open mouse gesture with one `onEnd`, or with nothing when it
    /// left the value as it was; does nothing when none is open. The mouse-up
    /// action and the return of the tracking loop both call it, and the first
    /// ends the gesture.
    func endGesture() {
      guard isGestureOpen else {
        return
      }

      isGestureOpen = false
      let value = doubleValue.rounded()
      guard hasGestureMoved || value != gestureStartValue else {
        return
      }
      onEnd?(value)
    }

    // MARK: - Keyboard

    override func moveRight(_ sender: Any?) {
      step(by: rightArrowDirection, modifiers: currentModifiers)
    }

    override func moveLeft(_ sender: Any?) {
      step(by: -rightArrowDirection, modifiers: currentModifiers)
    }

    override func moveUp(_ sender: Any?) {
      step(by: 1, modifiers: currentModifiers)
    }

    override func moveDown(_ sender: Any?) {
      step(by: -1, modifiers: currentModifiers)
    }

    /// Page Up and Page Down move to the ends of the range, as `NSSlider`'s
    /// own do, as key steps.
    override func pageUp(_ sender: Any?) {
      keyStep(to: maxValue, modifiers: currentModifiers)
    }

    override func pageDown(_ sender: Any?) {
      keyStep(to: minValue, modifiers: currentModifiers)
    }

    /// Steps the value by `direction` key steps (large ones with Shift) and
    /// previews it. The key-up ends the operation.
    func step(by direction: Double, modifiers: NSEvent.ModifierFlags) {
      let amount = if modifiers.contains(.shift) { Self.largeKeyStep } else { Self.keyStep }
      keyStep(to: doubleValue + direction * amount, modifiers: modifiers)
    }

    /// Moves the value to `target` and previews it, as a key step that the
    /// key-up ends. A key pressed with Command steps nothing: AppKit delivers
    /// no key-up while Command is down, so nothing would end the step.
    func keyStep(to target: Double, modifiers: NSEvent.ModifierFlags) {
      guard isEnabled, modifiers.contains(.command) == false else {
        return
      }

      isKeyStepping = true
      move(to: target)
      onChange?(doubleValue)
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

    /// Ends the open key step with one `onEnd`; does nothing when none is
    /// open.
    private func endKeyStep() {
      guard isKeyStepping else {
        return
      }

      isKeyStepping = false
      onEnd?(doubleValue)
      showShownValue()
    }

    /// Ends the open key step through `onEndLater` on the next turn; does
    /// nothing when none is open. Focus can leave, and SwiftUI can remove
    /// the slider, inside a view update, where nothing may be written.
    private func endKeyStepLater() {
      guard isKeyStepping else {
        return
      }

      isKeyStepping = false
      showShownValue()
      let onEndLater = onEndLater
      Task { @MainActor in
        onEndLater?()
      }
    }

    /// Returns the knob to what the editor shows once a key step ends. The
    /// two differ when the editor ended the operation first (Revert, Cancel,
    /// the host's undo) and takes nothing from the step, and while an update
    /// for the step's latest values is still to come, which then moves the
    /// knob to them.
    private func showShownValue() {
      if abs(doubleValue - shownValue) >= 0.5 {
        doubleValue = shownValue
      }
    }

    // MARK: - Window

    /// Watches the window's key and main state, which decide the bar's fill,
    /// so the slider redraws as it changes. The window resigning key also
    /// ends a key step, as losing focus does, because the key-up then goes
    /// elsewhere.
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stopObservingWindow()
      guard let window else {
        return
      }

      let names = [
        NSWindow.didBecomeKeyNotification,
        NSWindow.didResignKeyNotification,
        NSWindow.didBecomeMainNotification,
        NSWindow.didResignMainNotification,
      ]
      windowObservers = names.map { name in
        NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated {
            self?.windowDidChangeState(name)
          }
        }
      }
    }

    private func windowDidChangeState(_ name: NSNotification.Name) {
      needsDisplay = true
      if name == NSWindow.didResignKeyNotification {
        endKeyStepLater()
      }
    }

    private func stopObservingWindow() {
      for observer in windowObservers {
        NotificationCenter.default.removeObserver(observer)
      }
      windowObservers = []
    }

    // MARK: - Accessibility

    override func accessibilityPerformIncrement() -> Bool {
      stepForAccessibility(by: 1)
    }

    override func accessibilityPerformDecrement() -> Bool {
      stepForAccessibility(by: -1)
    }

    override func accessibilityValueDescription() -> String? {
      valueDescription?(doubleValue) ?? super.accessibilityValueDescription()
    }

    /// Each VoiceOver step is an operation of its own: previewed and ended at
    /// once.
    private func stepForAccessibility(by direction: Double) -> Bool {
      guard isEnabled else {
        return false
      }

      move(to: doubleValue + direction * Self.accessibilityStep)
      onChange?(doubleValue)
      onEnd?(doubleValue)
      return true
    }

    // MARK: - Value

    /// Moves the value to `target`, rounded and clamped to the range.
    private func move(to target: Double) {
      doubleValue = min(max(target.rounded(), minValue), maxValue)
    }

    /// The right arrow's direction. Under right to left the minimum is at the
    /// right end, so the right arrow steps down, as `NSSlider`'s own does.
    private var rightArrowDirection: Double {
      if userInterfaceLayoutDirection == .rightToLeft {
        -1
      } else {
        1
      }
    }

    private var currentModifiers: NSEvent.ModifierFlags {
      NSApp.currentEvent?.modifierFlags ?? []
    }
  }

  /// Draws the bar for `track` and leaves the knob to the system: of the
  /// drawing, it overrides `drawBar(inside:flipped:)` only. It hands
  /// VoiceOver's steps to the control.
  final class Cell: NSSliderCell {

    var track: ImageEditor.AdjustmentSection.Track = .plain

    /// Where the plain track's fill starts.
    var neutral = 0.0

    override func drawBar(inside rect: NSRect, flipped: Bool) {
      // A 3-point bar, centered where the system draws its own.
      let bar = NSRect(x: rect.minX, y: rect.midY - 1.5, width: rect.width, height: 3)
      let barPath = NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5)

      switch track {
      case .plain:
        NSColor.quaternaryLabelColor.setFill()
        barPath.fill()
        fillFromNeutral(in: bar, flipped: flipped)
      case .temperature:
        drawGradient([.systemBlue, .systemGray, .systemYellow], in: barPath)
      case .tint:
        drawGradient([.systemGreen, .systemGray, .systemPink], in: barPath)
      }
    }

    /// The plain track's fill: the accent color while the window shows its
    /// controls active, when it is key or main, as AppKit's own controls
    /// do; otherwise secondary, and tertiary while the slider is disabled.
    var fillColor: NSColor {
      let window = controlView?.window
      if isEnabled == false {
        return .tertiaryLabelColor
      } else if window?.isKeyWindow == true || window?.isMainWindow == true {
        return .controlAccentColor
      } else {
        return .secondaryLabelColor
      }
    }

    /// Fills the bar between the neutral value and the knob with
    /// `fillColor`.
    private func fillFromNeutral(in bar: NSRect, flipped: Bool) {
      let span = maxValue - minValue
      guard span > 0 else {
        return
      }

      let knob = knobRect(flipped: flipped)
      // Where the knob's center would be at the neutral value; a neutral
      // value at either end of the range fills from that end of the bar.
      let leftToRightX: CGFloat = if neutral <= minValue {
        bar.minX
      } else if neutral >= maxValue {
        bar.maxX
      } else {
        bar.minX + knob.width / 2 + CGFloat((neutral - minValue) / span) * (bar.width - knob.width)
      }
      // AppKit mirrors the knob under right to left; the neutral end follows.
      let neutralX = if isRightToLeft {
        bar.minX + bar.maxX - leftToRightX
      } else {
        leftToRightX
      }
      let fill = NSRect(
        x: min(neutralX, knob.midX),
        y: bar.minY,
        width: abs(knob.midX - neutralX),
        height: bar.height
      )

      fillColor.setFill()
      NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5).fill()
    }

    /// Draws `colors` from the minimum's end of the bar to the maximum's,
    /// which is the left end under right to left.
    private func drawGradient(_ colors: [NSColor], in barPath: NSBezierPath) {
      let angle: CGFloat = if isRightToLeft { 180 } else { 0 }
      NSGradient(colors: colors)?.draw(in: barPath, angle: angle)
    }

    private var isRightToLeft: Bool {
      userInterfaceLayoutDirection == .rightToLeft
    }

    /// VoiceOver addresses the cell, the slider's accessibility element, and
    /// AppKit hands the cell its increments and decrements here, whichever
    /// accessibility API asked for them. The control steps them, so each one
    /// is an operation of its own.
    ///
    /// The override carries the method's deprecation, so its calls to super
    /// do not warn.
    @available(macOS, deprecated: 10.10)
    override func accessibilityPerformAction(_ action: NSAccessibility.Action) {
      // AppKit performs accessibility actions on the main thread.
      let isStep = MainActor.assumeIsolated {
        guard let control = controlView as? Control else {
          return false
        }

        switch action {
        case .increment:
          _ = control.accessibilityPerformIncrement()
          return true
        case .decrement:
          _ = control.accessibilityPerformDecrement()
          return true
        default:
          return false
        }
      }
      if isStep == false {
        super.accessibilityPerformAction(action)
      }
    }
  }

  /// The control's target: AppKit sends the action while the mouse tracks,
  /// and a last time at the mouse-up.
  @MainActor
  final class Coordinator: NSObject {

    @objc func valueChanged(_ sender: Control) {
      sender.actionDidFire(currentEventType: NSApp.currentEvent?.type)
    }
  }
}
#endif
