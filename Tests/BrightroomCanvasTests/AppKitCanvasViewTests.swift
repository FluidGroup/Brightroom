#if os(macOS)
import AppKit
import BrightroomParametric
import CoreImage
import Metal
import Testing

@testable import BrightroomUI

/// The AppKit `EditingCanvasView` on its own: its lifecycle at zero size and
/// outside a window, its first frame, its display link, how it reads and
/// passes on scroll events, its zoom commands and reports, its fit margin,
/// the pointer, the mouse and point sampling, the keyboard, the focus ring
/// and what VoiceOver reads, and when it builds a feature change.
@MainActor
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct AppKitCanvasViewTests {

  private static let imageSize = CGSize(width: 400, height: 200)

  private static func makeCanvas() -> EditingCanvasView {
    let image = CIImage(color: CIColor(red: 0.2, green: 0.5, blue: 0.8))
      .cropped(to: CGRect(origin: .zero, size: imageSize))
    return EditingCanvasView(
      source: EditingCanvasSource(editingSourceImage: image, imageSize: imageSize),
      feature: ImageEditorFeature(imageSize: imageSize)
    )
  }

  /// A superview that records the scroll and key events passed on to it.
  final class EventRecordingView: NSView {
    private(set) var receivedScrollEvents: [NSEvent] = []
    private(set) var receivedKeyEvents: [NSEvent] = []

    override func scrollWheel(with event: NSEvent) {
      receivedScrollEvents.append(event)
    }

    override func keyDown(with event: NSEvent) {
      receivedKeyEvents.append(event)
    }
  }

  private static func makeWindow(containing view: NSView) -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 400, height: 400),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    let container = EventRecordingView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
    window.contentView = container
    container.addSubview(view)
    return window
  }

  /// The scroll events the canvas's superview received.
  private static func forwardedScrollEvents(of canvas: EditingCanvasView) -> [NSEvent] {
    (canvas.superview as? EventRecordingView)?.receivedScrollEvents ?? []
  }

  /// The key events the canvas's superview received.
  private static func forwardedKeyEvents(of canvas: EditingCanvasView) -> [NSEvent] {
    (canvas.superview as? EventRecordingView)?.receivedKeyEvents ?? []
  }

  /// Ticks the display link by hand until it pauses, as frames would.
  private static func tickUntilPaused(_ canvas: EditingCanvasView) {
    for _ in 0..<10 where canvas.displayLink.isPaused == false {
      canvas.drawViewportFrame()
    }
  }

  // MARK: - Lifecycle

  @Test
  func `Outside a window and at zero size nothing is drawn`() throws {
    let canvas = Self.makeCanvas()
    // Not in a window: layout and a tick draw nothing.
    canvas.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
    canvas.layout()
    canvas.drawViewportFrame()
    #expect(canvas.surface.displayedViewport == nil)
    #expect(canvas.surface.canvasView?.hasRenderImages == true)

    // In a window at zero size: still nothing, and nothing divides by zero.
    canvas.frame = .zero
    let window = Self.makeWindow(containing: canvas)
    defer { window.close() }
    window.contentView?.layoutSubtreeIfNeeded()
    canvas.layout()
    canvas.drawViewportFrame()
    #expect(canvas.surface.displayedViewport == nil)
    canvas.invalidate()
  }

  @Test
  func `Layout in a window draws the first frame fitted`() throws {
    let canvas = Self.makeCanvas()
    let window = Self.makeWindow(containing: canvas)
    defer { window.close() }
    canvas.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
    canvas.layout()

    // Drawn during layout, without input or a display-link tick.
    let viewport = try #require(canvas.surface.displayedViewport)
    #expect(canvas.navigation.isFitted)
    #expect(abs(viewport.contentToCanvasTransform.a - 0.75) < 1e-9)
    #expect(abs(viewport.contentToCanvasTransform.ty - 75) < 1e-9)
    canvas.invalidate()
  }

  @Test
  func `The display link pauses when idle and resumes for changes`() throws {
    let canvas = Self.makeCanvas()
    let window = Self.makeWindow(containing: canvas)
    defer { window.close() }
    canvas.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
    canvas.layout()
    canvas.areAnimationsEnabled = false
    #expect(canvas.displayLink.isScheduled)

    // Layout drew the first frame; the next tick finds nothing to do.
    #expect(canvas.displayLink.isPaused == false)
    #expect(canvas.surface.canvasView?.hasPendingDisplay == false)
    canvas.drawViewportFrame()
    #expect(canvas.displayLink.isPaused)

    // A feature change resumes it.
    var feature = canvas.feature
    feature.vignette = VignetteFeature(value: 0.5)
    canvas.setFeature(feature)
    #expect(canvas.displayLink.isPaused == false)
    Self.tickUntilPaused(canvas)
    #expect(canvas.displayLink.isPaused)

    // So does input.
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 0, phase: Self.mayBegin))
    #expect(canvas.displayLink.isPaused == false)
    Self.tickUntilPaused(canvas)
    #expect(canvas.displayLink.isPaused)

    // And layout.
    canvas.layout()
    #expect(canvas.displayLink.isPaused == false)

    // Invalidation unschedules it, and nothing resumes it afterwards.
    canvas.invalidate()
    #expect(canvas.displayLink.isScheduled == false)
    canvas.layout()
    #expect(canvas.displayLink.isScheduled == false)
  }

  @Test
  func `An invalidated canvas is released once removed, with its link`() throws {
    weak var released: EditingCanvasView?
    weak var releasedLink: ViewportDisplayLink?
    var window: NSWindow?
    autoreleasepool {
      let canvas = Self.makeCanvas()
      window = Self.makeWindow(containing: canvas)
      canvas.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
      canvas.layout()
      canvas.drawViewportFrame()
      released = canvas
      releasedLink = canvas.displayLink
      canvas.removeFromSuperview()
      canvas.invalidate()
    }
    defer { window?.close() }
    #expect(released == nil)
    #expect(releasedLink == nil)
  }

  @Test
  func `A canvas released without invalidate() invalidates its paused link`() throws {
    weak var released: EditingCanvasView?
    weak var releasedLink: ViewportDisplayLink?
    var window: NSWindow?
    autoreleasepool {
      let canvas = Self.makeCanvas()
      window = Self.makeWindow(containing: canvas)
      canvas.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
      canvas.layout()
      canvas.drawViewportFrame()
      // A paused link gets no ticks, so only the canvas's deinit can
      // invalidate it; a scheduled link would keep its proxy alive.
      #expect(canvas.displayLink.isPaused)
      #expect(canvas.displayLink.isScheduled)
      released = canvas
      releasedLink = canvas.displayLink
      canvas.removeFromSuperview()
    }
    defer { window?.close() }
    #expect(released == nil)
    #expect(releasedLink == nil)
  }

  // MARK: - Scroll events

  /// A pixel scroll event, as a trackpad sends one.
  ///
  /// - Parameter time: When the event happened, on the clock of
  ///   `CACurrentMediaTime()`, as the system stamps a real event. An event
  ///   made in code carries no time without it.
  private static func scrollEvent(
    deltaY: Int32,
    phase: Int64 = 0,
    momentumPhase: Int64 = 0,
    command: Bool = false,
    time: TimeInterval? = nil
  ) throws -> NSEvent {
    let cgEvent = try #require(CGEvent(
      scrollWheelEvent2Source: nil,
      units: .pixel,
      wheelCount: 1,
      wheel1: deltaY,
      wheel2: 0,
      wheel3: 0
    ))
    cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
    cgEvent.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
    if command {
      cgEvent.flags = .maskCommand
    }
    if let time {
      // Nanoseconds.
      cgEvent.timestamp = CGEventTimestamp(time * 1_000_000_000)
    }
    // Over the centre of the canvas, which `makeWindow` puts at (150, 150)
    // in a window whose content starts at the screen's origin. The event has
    // no window, so its location in window is this point on the screen.
    let screenHeight = NSScreen.screens.first?.frame.height ?? 0
    cgEvent.location = CGPoint(x: 150, y: screenHeight - 150)
    return try #require(NSEvent(cgEvent: cgEvent))
  }

  // CGEvent scroll phases.
  private static let began: Int64 = 1
  private static let changed: Int64 = 2
  private static let ended: Int64 = 4
  private static let cancelled: Int64 = 8
  private static let mayBegin: Int64 = 128
  // CGEvent momentum phases.
  private static let momentumBegan: Int64 = 1
  private static let momentumChanged: Int64 = 2
  private static let momentumEnded: Int64 = 3

  @Test
  func `A Command-scroll gesture stays a zoom until its momentum ends`() throws {
    let canvas = Self.makeCanvas()
    let window = Self.makeWindow(containing: canvas)
    defer { window.close() }
    canvas.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
    canvas.layout()
    canvas.areAnimationsEnabled = false
    let fit = canvas.navigation.fitScale

    // Begun with Command: the gesture zooms, even after Command is released.
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 100, phase: Self.began, command: true))
    let zoomed = canvas.navigation.position.scale
    #expect(zoomed > fit)
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 20, phase: Self.changed))
    #expect(canvas.navigation.position.scale != zoomed)
    let afterGesture = canvas.navigation.position
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 0, phase: Self.ended))

    // Its momentum is ignored while zooming.
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 30, momentumPhase: Self.momentumBegan))
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 30, momentumPhase: Self.momentumChanged))
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 0, momentumPhase: Self.momentumEnded))
    #expect(canvas.navigation.position == afterGesture)

    // The next gesture, without Command, decides again: it pans.
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 0, phase: Self.mayBegin))
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 15, phase: Self.began))
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 15, phase: Self.changed))
    #expect(canvas.navigation.position.scale == afterGesture.scale)
    #expect(canvas.navigation.position.center != afterGesture.center)
    canvas.invalidate()
  }

  @Test
  func `A legacy wheel event decides on its own`() throws {
    let canvas = Self.makeCanvas()
    let window = Self.makeWindow(containing: canvas)
    defer { window.close() }
    canvas.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
    canvas.layout()
    canvas.areAnimationsEnabled = false
    let fit = canvas.navigation.fitScale

    // At the fit there is nothing to scroll: the event is passed on.
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 10))
    #expect(canvas.navigation.isFitted)
    #expect(Self.forwardedScrollEvents(of: canvas).count == 1)

    // With Command it zooms, and is not passed on.
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 100, command: true))
    let zoomed = canvas.navigation.position
    #expect(zoomed.scale > fit)
    #expect(Self.forwardedScrollEvents(of: canvas).count == 1)

    // The next one, without Command, pans: no mode was left latched.
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 10))
    #expect(canvas.navigation.position.scale == zoomed.scale)
    #expect(canvas.navigation.position.center != zoomed.center)
    #expect(Self.forwardedScrollEvents(of: canvas).count == 1)
    canvas.invalidate()
  }

  @Test
  func `At the fit a touch and its gesture are passed on whole`() throws {
    let canvas = Self.makeCanvas()
    let window = Self.makeWindow(containing: canvas)
    defer { window.close() }
    canvas.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
    canvas.layout()
    canvas.areAnimationsEnabled = false
    let fit = canvas.navigation.fitScale

    // A touch that lifts without moving: its start and its end.
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 0, phase: Self.mayBegin))
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 0, phase: Self.cancelled))
    #expect(Self.forwardedScrollEvents(of: canvas).map(\.phase) == [.mayBegin, .cancelled])

    // A gesture: every event, from its `.mayBegin` to its momentum's end.
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 0, phase: Self.mayBegin))
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 10, phase: Self.began))
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 10, phase: Self.changed))
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 0, phase: Self.ended))
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 5, momentumPhase: Self.momentumBegan))
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 0, momentumPhase: Self.momentumEnded))
    #expect(Self.forwardedScrollEvents(of: canvas).count == 8)
    #expect(canvas.navigation.isFitted)

    // Zoomed in, the canvas scrolls and keeps every event.
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 100, command: true))
    #expect(canvas.navigation.position.scale > fit)
    let forwarded = Self.forwardedScrollEvents(of: canvas).count
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 0, phase: Self.mayBegin))
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 0, phase: Self.cancelled))
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 0, phase: Self.mayBegin))
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 10, phase: Self.began))
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 0, phase: Self.ended))
    #expect(Self.forwardedScrollEvents(of: canvas).count == forwarded)
    canvas.invalidate()
  }

  @Test(.enabled(if: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false))
  func `Momentum that reaches the edge bounces as deep as the events' times say it is fast`() throws {
    let canvas = Self.makeCanvas()
    let window = Self.makeWindow(containing: canvas)
    defer { window.close() }
    canvas.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
    canvas.layout()
    // Zoomed in, so the content scrolls.
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 100, command: true))
    let scale = canvas.navigation.position.scale
    #expect(canvas.navigation.canScroll)

    // A gesture and its momentum, a sixtieth of a second apart and stamped in
    // the recent past, as the system stamps the events it delivers. The last
    // of them is stamped a thirtieth of a second ago, which leaves the test
    // most of the half second an event's time counts as plausible for.
    let interval = 1.0 / 60
    let first = CACurrentMediaTime() - 0.1
    var time = first
    func send(deltaY: Int32, phase: Int64 = 0, momentumPhase: Int64 = 0) throws {
      canvas.scrollWheel(
        with: try Self.scrollEvent(
          deltaY: deltaY, phase: phase, momentumPhase: momentumPhase, time: time
        )
      )
      time += interval
    }
    try send(deltaY: 0, phase: Self.mayBegin)
    try send(deltaY: 10, phase: Self.began)
    try send(deltaY: 0, phase: Self.ended)
    let released = canvas.navigation.position.center
    #expect(canvas.navigation.isMoving == false)

    try send(deltaY: 30, momentumPhase: Self.momentumBegan)
    // How far one such event moves the content on the canvas, in points.
    let step = (released.y - canvas.navigation.position.center.y) * scale
    #expect(step > 0)
    // No further than the present: an event from the future carries no
    // plausible time.
    while canvas.navigation.isMoving == false, time < first + 0.09 {
      try send(deltaY: 30, momentumPhase: Self.momentumChanged)
    }
    // The content reached its edge and bounces there.
    #expect(canvas.navigation.isMoving)

    // The bounce is as deep as the momentum was fast: a critically damped
    // spring of angular frequency 10 that leaves its rest at `v` goes
    // `v / (10 e)` away. Had the canvas timed the events by when it handled
    // them, microseconds apart, there would be no such speed to bounce with.
    let limit = canvas.bounds.height / (2 * scale)
    var navigation = canvas.navigation
    var deepest: CGFloat = 0
    for sample in stride(from: first, through: CACurrentMediaTime() + 0.5, by: 0.001) {
      navigation.advance(to: sample)
      deepest = max(deepest, (limit - navigation.position.center.y) * scale)
    }
    let expected = (step / interval) / (10 * M_E)
    #expect(abs(deepest - expected) < 0.01 * expected)
    canvas.invalidate()
  }

  @Test(.enabled(if: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false))
  func `Momentum takes content the fingers left past the edge back inside and on`() throws {
    let canvas = Self.makeCanvas()
    let window = Self.makeWindow(containing: canvas)
    defer { window.close() }
    canvas.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
    canvas.layout()
    // Zoomed in, so the content scrolls.
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 100, command: true))
    let scale = canvas.navigation.position.scale
    // The centre that shows the content's top edge at the canvas's.
    let limit = canvas.bounds.height / (2 * scale)

    // Events a hundred and twentieth of a second apart, stamped in the
    // recent past.
    let interval = 1.0 / 120
    var time = CACurrentMediaTime() - 0.2
    func send(deltaY: Int32, phase: Int64 = 0, momentumPhase: Int64 = 0) throws {
      canvas.scrollWheel(
        with: try Self.scrollEvent(
          deltaY: deltaY, phase: phase, momentumPhase: momentumPhase, time: time
        )
      )
      time += interval
    }
    var centre: CGFloat { canvas.navigation.position.center.y }
    /// What a rubber band over the canvas's 300 points shows of a pull.
    func shown(_ pull: CGFloat) -> CGFloat {
      (1 - 1 / (pull * 0.55 / 300 + 1)) * 300
    }

    // How far one event of 10 moves the content down, in points.
    let before = centre
    try send(deltaY: 0, phase: Self.mayBegin)
    try send(deltaY: 10, phase: Self.began)
    try send(deltaY: 0, phase: Self.ended)
    let step = (before - centre) * scale
    #expect(step > 0)

    // Fingers pull the content down past its top edge, come back by two
    // events, and lift while still past it.
    let toEdge = (centre - limit) * scale
    let events = Int32(((toEdge + 40) / step).rounded(.up))
    try send(deltaY: 0, phase: Self.mayBegin)
    try send(deltaY: 10 * events, phase: Self.began)
    try send(deltaY: -10, phase: Self.changed)
    try send(deltaY: -10, phase: Self.changed)
    try send(deltaY: 0, phase: Self.ended)
    let pull = CGFloat(events) * step - toEdge - 2 * step
    #expect(pull > step)
    #expect(abs(centre - (limit - shown(pull) / scale)) < 1e-6)

    // The momentum moves the pull on as the fingers did, shown through the
    // rubber band.
    try send(deltaY: -10, momentumPhase: Self.momentumBegan)
    #expect(abs(centre - (limit - shown(pull - step) / scale)) < 1e-6)

    // Once the content is back inside it moves as the momentum does.
    var moved = step
    while centre <= limit, moved < pull + 4 * step {
      try send(deltaY: -10, momentumPhase: Self.momentumChanged)
      moved += step
    }
    #expect(abs(centre - (limit + (moved - pull) / scale)) < 1e-6)
    try send(deltaY: -10, momentumPhase: Self.momentumChanged)
    #expect(abs(centre - (limit + (moved + step - pull) / scale)) < 1e-6)
    try send(deltaY: 0, momentumPhase: Self.momentumEnded)
    #expect(canvas.navigation.isMoving == false)
    canvas.invalidate()
  }

  @Test
  func `An event's time is its timestamp when that is plausible, and now otherwise`() {
    let now: TimeInterval = 5000
    func time(of timestamp: TimeInterval) -> TimeInterval {
      EditingCanvasView.inputTime(timestamp: timestamp, now: now)
    }
    // A recent event, and one stamped a moment ahead of the clock read.
    #expect(time(of: now - 0.1) == now - 0.1)
    #expect(time(of: now - 0.49) == now - 0.49)
    #expect(time(of: now + 0.004) == now + 0.004)
    // An event made in code carries no time; one from long ago or from the
    // future carries none worth measuring with.
    #expect(time(of: 0) == now)
    #expect(time(of: now - 0.6) == now)
    #expect(time(of: now + 0.01) == now)
    #expect(time(of: -1) == now)
    // No time is no time even when the clock itself is young.
    #expect(EditingCanvasView.inputTime(timestamp: 0, now: 0.2) == 0.2)
  }

  /// A pinch event, which cannot be made from a `CGEvent`. The canvas reads
  /// only what is overridden here.
  private final class PinchEvent: NSEvent {
    private let pinchMagnification: CGFloat
    private let pinchPhase: NSEvent.Phase
    private let pinchTime: TimeInterval

    init(magnification: CGFloat, phase: NSEvent.Phase, time: TimeInterval) {
      pinchMagnification = magnification
      pinchPhase = phase
      pinchTime = time
      super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override var magnification: CGFloat { pinchMagnification }
    override var phase: NSEvent.Phase { pinchPhase }
    override var timestamp: TimeInterval { pinchTime }
    // The centre of the canvas, which `makeWindow` puts at (150, 150).
    override var locationInWindow: NSPoint { NSPoint(x: 150, y: 250) }
  }

  @Test(.enabled(if: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false))
  func `A gesture passed on while the zoom is stopped below the fit lets the zoom finish`() throws {
    let canvas = Self.makeCanvas()
    let window = Self.makeWindow(containing: canvas)
    defer { window.close() }
    canvas.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
    canvas.layout()
    let fit = canvas.navigation.fitScale

    // A pinch out past the fit, released: the zoom starts back to the fit.
    var time = CACurrentMediaTime() - 0.1
    func pinch(_ magnification: CGFloat, _ phase: NSEvent.Phase) {
      canvas.magnify(with: PinchEvent(magnification: magnification, phase: phase, time: time))
      time += 0.01
    }
    pinch(-0.3, .began)
    pinch(-0.3, .changed)
    pinch(0, .ended)
    #expect(canvas.navigation.position.scale < fit)
    #expect(canvas.navigation.isMoving)

    // Fingers land and stop it there, below the fit, where nothing scrolls.
    func scroll(deltaY: Int32, phase: Int64) throws {
      canvas.scrollWheel(with: try Self.scrollEvent(deltaY: deltaY, phase: phase, time: time))
      time += 0.01
    }
    try scroll(deltaY: 0, phase: Self.mayBegin)
    #expect(canvas.navigation.isMoving == false)
    #expect(canvas.navigation.position.scale < fit)
    #expect(canvas.navigation.canScroll == false)

    // Their gesture is passed on, so the canvas has no touch to wait for:
    // the zoom goes on to the fit.
    try scroll(deltaY: 10, phase: Self.began)
    #expect(canvas.navigation.isMoving)
    try scroll(deltaY: 10, phase: Self.changed)
    try scroll(deltaY: 0, phase: Self.ended)
    #expect(
      Self.forwardedScrollEvents(of: canvas).map(\.phase) == [.mayBegin, .began, .changed, .ended]
    )
    var navigation = canvas.navigation
    navigation.advance(to: CACurrentMediaTime() + 2)
    #expect(navigation.isMoving == false)
    #expect(navigation.isFitted)
    canvas.invalidate()
  }

  @Test
  func `A scroll passed on during a pinch leaves the pinch its zoom`() throws {
    let canvas = Self.makeCanvas()
    let window = Self.makeWindow(containing: canvas)
    defer { window.close() }
    canvas.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
    canvas.layout()
    let fit = canvas.navigation.fitScale

    var time = CACurrentMediaTime() - 0.1
    func pinch(_ magnification: CGFloat, _ phase: NSEvent.Phase) {
      canvas.magnify(with: PinchEvent(magnification: magnification, phase: phase, time: time))
      time += 0.01
    }
    func scroll(deltaY: Int32, phase: Int64) throws {
      canvas.scrollWheel(with: try Self.scrollEvent(deltaY: deltaY, phase: phase, time: time))
      time += 0.01
    }

    // A pinch out past the fit that the fingers still hold.
    pinch(-0.3, .began)
    pinch(-0.3, .changed)
    let pinched = canvas.navigation.position
    #expect(pinched.scale < fit)
    #expect(canvas.navigation.isMoving == false)

    // The fingers also move: below the fit nothing scrolls, so that gesture
    // is passed on. The zoom stays where the pinch holds it.
    try scroll(deltaY: 10, phase: Self.began)
    try scroll(deltaY: 10, phase: Self.changed)
    #expect(Self.forwardedScrollEvents(of: canvas).map(\.phase) == [.began, .changed])
    #expect(canvas.navigation.position == pinched)
    #expect(canvas.navigation.isMoving == false)

    // The fingers lift: the pinch's end lets the zoom go back to the fit,
    // and the scroll's end, passed on, leaves that alone.
    pinch(0, .ended)
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    #expect(canvas.navigation.isMoving == (reduceMotion == false))
    try scroll(deltaY: 0, phase: Self.ended)
    #expect(Self.forwardedScrollEvents(of: canvas).map(\.phase) == [.began, .changed, .ended])
    #expect(canvas.navigation.isMoving == (reduceMotion == false))
    var navigation = canvas.navigation
    navigation.advance(to: CACurrentMediaTime() + 2)
    #expect(navigation.isFitted)
    canvas.invalidate()
  }

  @Test
  func `A resting touch that turns into a pinch is cancelled without ending the pinch`() throws {
    let canvas = Self.makeCanvas()
    let window = Self.makeWindow(containing: canvas)
    defer { window.close() }
    canvas.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
    canvas.layout()
    let fit = canvas.navigation.fitScale

    var time = CACurrentMediaTime() - 0.1
    func pinch(_ magnification: CGFloat, _ phase: NSEvent.Phase) {
      canvas.magnify(with: PinchEvent(magnification: magnification, phase: phase, time: time))
      time += 0.01
    }
    func scroll(deltaY: Int32, phase: Int64) throws {
      canvas.scrollWheel(with: try Self.scrollEvent(deltaY: deltaY, phase: phase, time: time))
      time += 0.01
    }

    // Fingers rest, then pinch out past the fit and hold.
    try scroll(deltaY: 0, phase: Self.mayBegin)
    pinch(-0.3, .began)
    pinch(-0.3, .changed)
    let pinched = canvas.navigation.position
    #expect(pinched.scale < fit)

    // The touch was no scroll after all, and is cancelled: the surrounding
    // views, which saw it start, see that. The pinch keeps its zoom.
    try scroll(deltaY: 0, phase: Self.cancelled)
    #expect(Self.forwardedScrollEvents(of: canvas).map(\.phase) == [.mayBegin, .cancelled])
    #expect(canvas.navigation.position == pinched)
    #expect(canvas.navigation.isMoving == false)

    pinch(0, .ended)
    var navigation = canvas.navigation
    navigation.advance(to: CACurrentMediaTime() + 2)
    #expect(navigation.isFitted)
    canvas.invalidate()
  }

  @Test
  func `A pinch whose end never arrives lets the end of the next gesture bring the zoom back`() throws {
    let canvas = Self.makeCanvas()
    let window = Self.makeWindow(containing: canvas)
    defer { window.close() }
    canvas.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
    canvas.layout()
    let fit = canvas.navigation.fitScale

    var time = CACurrentMediaTime() - 0.1
    func scroll(deltaY: Int32, phase: Int64) throws {
      canvas.scrollWheel(with: try Self.scrollEvent(deltaY: deltaY, phase: phase, time: time))
      time += 0.01
    }

    // A pinch out past the fit whose end is lost.
    canvas.magnify(with: PinchEvent(magnification: -0.3, phase: .began, time: time))
    time += 0.01
    let pinched = canvas.navigation.position
    #expect(pinched.scale < fit)

    // A swipe that starts without resting first is passed on. Its end means
    // the fingers have lifted, so the zoom goes back to the fit.
    try scroll(deltaY: 10, phase: Self.began)
    #expect(canvas.navigation.position == pinched)
    try scroll(deltaY: 0, phase: Self.ended)
    var navigation = canvas.navigation
    navigation.advance(to: CACurrentMediaTime() + 2)
    #expect(navigation.isMoving == false)
    #expect(navigation.isFitted)
    canvas.invalidate()
  }

  @Test
  func `A resting touch after a pinch whose end never arrives brings the zoom back`() throws {
    let canvas = Self.makeCanvas()
    let window = Self.makeWindow(containing: canvas)
    defer { window.close() }
    canvas.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
    canvas.layout()
    let fit = canvas.navigation.fitScale

    // A pinch out past the fit whose end is lost.
    var time = CACurrentMediaTime() - 0.1
    canvas.magnify(with: PinchEvent(magnification: -0.3, phase: .began, time: time))
    time += 0.01
    #expect(canvas.navigation.position.scale < fit)

    // Fingers land anew and lift without a gesture: the lost pinch is over.
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 0, phase: Self.mayBegin, time: time))
    time += 0.01
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 0, phase: Self.cancelled, time: time))
    var navigation = canvas.navigation
    navigation.advance(to: CACurrentMediaTime() + 2)
    #expect(navigation.isMoving == false)
    #expect(navigation.isFitted)
    canvas.invalidate()
  }

  @Test
  func `A touch whose start was passed on has its end passed on when the canvas takes its gesture`() throws {
    let canvas = Self.makeCanvas()
    let window = Self.makeWindow(containing: canvas)
    defer { window.close() }
    canvas.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
    canvas.layout()
    canvas.areAnimationsEnabled = false
    let fit = canvas.navigation.fitScale

    // Fingers rest at the fit, where nothing scrolls: their start is passed
    // on. Command is pressed before they move, so the gesture zooms.
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 0, phase: Self.mayBegin))
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 100, phase: Self.began, command: true))
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 20, phase: Self.changed, command: true))
    #expect(canvas.navigation.position.scale > fit)
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 0, phase: Self.ended, command: true))
    // The momentum that follows a gesture the canvas took stays with it.
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 5, momentumPhase: Self.momentumBegan))
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 0, momentumPhase: Self.momentumEnded))
    #expect(Self.forwardedScrollEvents(of: canvas).map(\.phase) == [.mayBegin, .ended])

    // Zoomed in, a touch is the canvas's from its start: nothing is passed.
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 0, phase: Self.mayBegin))
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 10, phase: Self.began))
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 0, phase: Self.ended))
    #expect(Self.forwardedScrollEvents(of: canvas).count == 2)

    // Back at the fit, fingers rest (their start is passed on), pinch in to
    // 2.7 times the fit so that the content scrolls both ways, and then pan:
    // the pan is the canvas's, and its end is passed on.
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: -1000, command: true))
    #expect(canvas.navigation.isFitted)
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 0, phase: Self.mayBegin))
    let now = CACurrentMediaTime()
    canvas.magnify(with: PinchEvent(magnification: 1, phase: .began, time: now))
    canvas.magnify(with: PinchEvent(magnification: 0, phase: .ended, time: now))
    #expect(canvas.navigation.canScroll)
    let zoomed = canvas.navigation.position
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 10, phase: Self.began))
    #expect(canvas.navigation.position.center != zoomed.center)
    canvas.scrollWheel(with: try Self.scrollEvent(deltaY: 0, phase: Self.cancelled))
    #expect(
      Self.forwardedScrollEvents(of: canvas).map(\.phase)
        == [.mayBegin, .ended, .mayBegin, .cancelled]
    )
    canvas.invalidate()
  }

  // MARK: - Zoom commands and reports

  /// A canvas of 300 x 300 points in a window, laid out: the 400 x 200
  /// output fits at 0.75, 300 x 150 points, 75 points below the top.
  private static func makeLaidOutCanvas() -> (EditingCanvasView, NSWindow) {
    let canvas = makeCanvas()
    let window = makeWindow(containing: canvas)
    canvas.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
    canvas.layout()
    return (canvas, window)
  }

  private static func isClose(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
    abs(lhs - rhs) < 1e-9
  }

  private static func isClose(_ lhs: CGPoint?, _ rhs: CGPoint) -> Bool {
    guard let lhs else { return false }
    return isClose(lhs.x, rhs.x) && isClose(lhs.y, rhs.y)
  }

  @Test
  func `The zoom commands step about the centre, fit, and go to a fraction of the range`() throws {
    let (canvas, window) = Self.makeLaidOutCanvas()
    defer { window.close() }
    canvas.areAnimationsEnabled = false
    let fit = canvas.navigation.fitScale
    #expect(Self.isClose(fit, 0.75))
    let centre = canvas.navigation.position.center

    canvas.zoomIn()
    #expect(Self.isClose(canvas.navigation.position.scale, 2 * fit))
    #expect(Self.isClose(canvas.navigation.position.center, centre))
    canvas.zoomIn()
    #expect(Self.isClose(canvas.navigation.position.scale, 4 * fit))
    canvas.zoomOut()
    #expect(Self.isClose(canvas.navigation.position.scale, 2 * fit))
    canvas.zoomToFit()
    #expect(canvas.navigation.isFitted)
    canvas.zoomOut()
    #expect(canvas.navigation.isFitted)

    canvas.zoom(toFraction: 1)
    #expect(Self.isClose(canvas.navigation.position.scale, 8 * fit))
    // The range is three doublings of the fit.
    canvas.zoom(toFraction: 1.0 / 3)
    #expect(Self.isClose(canvas.navigation.position.scale, 2 * fit))
    #expect(Self.isClose(canvas.navigation.position.center, centre))
    #expect(canvas.navigation.isMoving == false)
    canvas.invalidate()
  }

  @Test
  func `The zoom is reported once per change, and a command's before it returns`() throws {
    let canvas = Self.makeCanvas()
    let window = Self.makeWindow(containing: canvas)
    defer { window.close() }
    var zooms: [ImageEditorCanvas.Zoom] = []
    canvas.onZoomChange = { zooms.append($0) }

    // Nothing is shown at zero size, so nothing is reported.
    canvas.layout()
    #expect(zooms.isEmpty)

    // The first frame reports the fit.
    canvas.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
    canvas.layout()
    canvas.areAnimationsEnabled = false
    let fitted = try #require(zooms.first)
    #expect(zooms.count == 1)
    #expect(fitted.isFitted)
    #expect(Self.isClose(fitted.scale, 0.75))
    #expect(Self.isClose(fitted.maximumScale, 6))
    #expect(fitted.backingScaleFactor == window.backingScaleFactor)

    // Frames that change nothing report nothing.
    Self.tickUntilPaused(canvas)
    canvas.layout()
    #expect(zooms.count == 1)

    canvas.zoomIn()
    #expect(zooms.count == 2)
    #expect(Self.isClose(zooms.last?.scale ?? 0, 1.5))
    canvas.zoomIn()
    canvas.zoomIn()
    #expect(zooms.count == 4)
    #expect(zooms.last?.isAtMaximum == true)
    // At the maximum a step changes nothing, and reports nothing.
    canvas.zoomIn()
    Self.tickUntilPaused(canvas)
    #expect(zooms.count == 4)

    canvas.zoom(toFraction: 0.5)
    #expect(zooms.count == 5)
    #expect(abs((zooms.last?.fraction ?? 0) - 0.5) < 1e-9)

    canvas.zoomToFit()
    #expect(zooms.count == 6)
    #expect(zooms.last == fitted)
    canvas.invalidate()
  }

  @Test(.enabled(if: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false))
  func `An animated zoom step reports from the frames of its motion, and a zoom to a fraction before it returns`() async throws {
    let canvas = Self.makeCanvas()
    let window = Self.makeWindow(containing: canvas)
    defer { window.close() }
    var zooms: [ImageEditorCanvas.Zoom] = []
    canvas.onZoomChange = { zooms.append($0) }
    canvas.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
    canvas.layout()
    #expect(zooms.count == 1)

    canvas.zoomIn()
    #expect(zooms.count == 1, "The step has only started its motion.")
    #expect(canvas.navigation.isMoving)
    for _ in 0..<250 where canvas.navigation.isMoving {
      canvas.drawViewportFrame()
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(zooms.count > 1)
    #expect(Self.isClose(zooms.last?.scale ?? 0, 1.5))

    let reported = zooms.count
    canvas.zoom(toFraction: 1)
    #expect(zooms.count == reported + 1)
    #expect(zooms.last?.isAtMaximum == true)
    canvas.invalidate()
  }

  @Test
  func `A fit margin leaves room around the fitted output, and a change of it shows on the next frame`() throws {
    let canvas = Self.makeCanvas()
    let window = Self.makeWindow(containing: canvas)
    defer { window.close() }
    // Before the first layout, as the representable sets it.
    canvas.fitMargin = 12
    canvas.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
    canvas.layout()

    // The 400 x 200 output fits the 276 points inside the margins at 0.69:
    // 276 x 138 points, 12 from the sides and 81 from the top.
    let fitted = try #require(canvas.surface.displayedViewport).contentToCanvasTransform
    #expect(Self.isClose(fitted.a, 0.69))
    #expect(Self.isClose(fitted.tx, 12))
    #expect(Self.isClose(fitted.ty, 81))

    canvas.fitMargin = 0
    #expect(canvas.displayLink.isPaused == false)
    canvas.drawViewportFrame()
    #expect(canvas.navigation.isFitted)
    let unmargined = try #require(canvas.surface.displayedViewport).contentToCanvasTransform
    #expect(Self.isClose(unmargined.a, 0.75))
    #expect(Self.isClose(unmargined.tx, 0))
    canvas.invalidate()
  }

  @Test
  func `A canvas point maps to the output point under it, and off the image to nil`() throws {
    let canvas = Self.makeCanvas()
    let window = Self.makeWindow(containing: canvas)
    defer { window.close() }
    func outputPoint(_ x: CGFloat, _ y: CGFloat) -> CGPoint? {
      canvas.outputPoint(forCanvasPoint: CGPoint(x: x, y: y))
    }
    // Before the first frame no point is under the pointer.
    #expect(outputPoint(150, 150) == nil)

    canvas.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
    canvas.layout()
    #expect(Self.isClose(outputPoint(150, 150), CGPoint(x: 200, y: 100)))
    #expect(Self.isClose(outputPoint(0, 75), .zero))
    #expect(Self.isClose(outputPoint(299, 224), CGPoint(x: 299 / 0.75, y: 149 / 0.75)))
    // Above and below the letterboxed output.
    #expect(outputPoint(150, 50) == nil)
    #expect(outputPoint(150, 260) == nil)

    // Zoomed in about the centre, the same point shows another pixel.
    canvas.areAnimationsEnabled = false
    canvas.zoomIn()
    #expect(Self.isClose(outputPoint(0, 150), CGPoint(x: 100, y: 100)))
    canvas.invalidate()
  }

  // MARK: - Pointer and mouse

  /// Passes `canvas` a mouse event of `type` at `canvasPoint`, made as the
  /// window makes one.
  private static func send(
    _ type: NSEvent.EventType,
    at canvasPoint: CGPoint,
    to canvas: EditingCanvasView
  ) throws {
    let window = try #require(canvas.window)
    let location = canvas.convert(canvasPoint, to: nil)
    switch type {
    case .mouseEntered, .mouseExited:
      let event = try #require(
        NSEvent.enterExitEvent(
          with: type,
          location: location,
          modifierFlags: [],
          timestamp: 0,
          windowNumber: window.windowNumber,
          context: nil,
          eventNumber: 0,
          trackingNumber: 0,
          userData: nil
        )
      )
      if type == .mouseEntered {
        canvas.mouseEntered(with: event)
      } else {
        canvas.mouseExited(with: event)
      }
    default:
      let event = try #require(
        NSEvent.mouseEvent(
          with: type,
          location: location,
          modifierFlags: [],
          timestamp: 0,
          windowNumber: window.windowNumber,
          context: nil,
          eventNumber: 0,
          clickCount: type == .mouseMoved ? 0 : 1,
          pressure: type == .leftMouseDown || type == .leftMouseDragged ? 1 : 0
        )
      )
      switch type {
      case .mouseMoved:
        canvas.mouseMoved(with: event)
      case .leftMouseDown:
        canvas.mouseDown(with: event)
      case .leftMouseDragged:
        canvas.mouseDragged(with: event)
      case .leftMouseUp:
        canvas.mouseUp(with: event)
      default:
        Issue.record("The canvas is not sent \(type) events")
      }
    }
  }

  @Test
  func `The pointer reports the whole output pixel under it, and nil off the image or once it leaves`() throws {
    let (canvas, window) = Self.makeLaidOutCanvas()
    defer { window.close() }
    canvas.areAnimationsEnabled = false
    var pointers: [CGPoint?] = []
    canvas.onPointerChange = { pointers.append($0) }

    // Over output (201.3, 101.3).
    try Self.send(.mouseEntered, at: CGPoint(x: 151, y: 151), to: canvas)
    #expect(pointers == [CGPoint(x: 201, y: 101)])
    // Within the same pixel nothing is reported.
    try Self.send(.mouseMoved, at: CGPoint(x: 151.2, y: 151.2), to: canvas)
    #expect(pointers.count == 1)
    // Above the letterboxed output.
    try Self.send(.mouseMoved, at: CGPoint(x: 151, y: 50), to: canvas)
    #expect(pointers == [CGPoint(x: 201, y: 101), nil])
    try Self.send(.mouseMoved, at: CGPoint(x: 151, y: 151), to: canvas)
    #expect(pointers.count == 3)

    // A zoom moves the image under the resting pointer: at 1.5 about the
    // centre it is over output (200.7, 100.7).
    canvas.zoomIn()
    #expect(pointers.count == 4)
    #expect(pointers.last == CGPoint(x: 200, y: 100))

    try Self.send(.mouseExited, at: CGPoint(x: -10, y: 151), to: canvas)
    #expect(pointers.count == 5)
    #expect(pointers.last == .some(nil))
    // Once the pointer has left, frames report nothing for it.
    canvas.zoomOut()
    Self.tickUntilPaused(canvas)
    #expect(pointers.count == 5)
    canvas.invalidate()
  }

  @Test
  func `A drag reports the pixel under the pointer, which a pan keeps, and nil off the canvas`() throws {
    let (canvas, window) = Self.makeLaidOutCanvas()
    defer { window.close() }
    canvas.areAnimationsEnabled = false
    var pointers: [CGPoint?] = []
    canvas.onPointerChange = { pointers.append($0) }

    // At the fit a drag pans nothing and moves the pointer over the image,
    // to output (213.3, 101.3), then off the canvas.
    try Self.send(.leftMouseDown, at: CGPoint(x: 151, y: 151), to: canvas)
    try Self.send(.leftMouseDragged, at: CGPoint(x: 160, y: 151), to: canvas)
    #expect(pointers == [CGPoint(x: 213, y: 101)])
    try Self.send(.leftMouseDragged, at: CGPoint(x: 320, y: 151), to: canvas)
    #expect(pointers == [CGPoint(x: 213, y: 101), nil])
    try Self.send(.leftMouseUp, at: CGPoint(x: 320, y: 151), to: canvas)

    // Zoomed in to 3, the pointer rests over output (200.3, 100.3).
    canvas.zoomIn()
    canvas.zoomIn()
    try Self.send(.mouseMoved, at: CGPoint(x: 151, y: 151), to: canvas)
    #expect(pointers.last == CGPoint(x: 200, y: 100))
    let reported = pointers.count

    // The image follows a drag that pans it, so the pixel under the pointer
    // stays the one the drag took hold of.
    try Self.send(.leftMouseDown, at: CGPoint(x: 151, y: 151), to: canvas)
    try Self.send(.leftMouseDragged, at: CGPoint(x: 121, y: 141), to: canvas)
    Self.tickUntilPaused(canvas)
    #expect(canvas.navigation.position.center.x > 200)
    #expect(pointers.count == reported)

    // Off the canvas the pan goes on, over no pixel.
    try Self.send(.leftMouseDragged, at: CGPoint(x: -20, y: 141), to: canvas)
    Self.tickUntilPaused(canvas)
    #expect(pointers.count == reported + 1)
    #expect(pointers.last == .some(nil))
    try Self.send(.leftMouseUp, at: CGPoint(x: -20, y: 141), to: canvas)
    canvas.invalidate()
  }

  @Test
  func `Dragging with the mouse pans only once zoomed in`() throws {
    let (canvas, window) = Self.makeLaidOutCanvas()
    defer { window.close() }
    canvas.areAnimationsEnabled = false
    func drag(through points: [CGPoint]) throws {
      try Self.send(.leftMouseDown, at: points[0], to: canvas)
      for point in points.dropFirst() {
        try Self.send(.leftMouseDragged, at: point, to: canvas)
      }
      try Self.send(.leftMouseUp, at: points[points.count - 1], to: canvas)
    }
    let path = [CGPoint(x: 150, y: 150), CGPoint(x: 120, y: 140), CGPoint(x: 110, y: 130)]

    // At the fit there is nothing to pan.
    let fitted = canvas.navigation.position
    try drag(through: path)
    #expect(canvas.navigation.position == fitted)

    // Zoomed in to 3, the content follows the mouse: 40 points left and 20
    // up move the centre the other way by that many points over the zoom.
    canvas.zoomIn()
    canvas.zoomIn()
    let zoomed = canvas.navigation.position
    #expect(canvas.navigation.canScroll)
    try drag(through: path)
    let panned = CGPoint(x: zoomed.center.x + 40 / 3, y: zoomed.center.y + 20 / 3)
    #expect(Self.isClose(canvas.navigation.position.center, panned))
    #expect(canvas.navigation.position.scale == zoomed.scale)
    #expect(canvas.navigation.isMoving == false)

    // Pulled past the left edge, where the centre's limit is 50, the content
    // goes back inside when the drag ends. The drag may leave the view.
    try drag(through: [CGPoint(x: 10, y: 150), CGPoint(x: 600, y: 150)])
    #expect(canvas.navigation.isMoving == false)
    #expect(Self.isClose(canvas.navigation.position.center.x, 50))
    canvas.invalidate()
  }

  @Test
  func `While a point is sampled, a click on the image samples it instead of panning, under a crosshair`() throws {
    let (canvas, window) = Self.makeLaidOutCanvas()
    defer { window.close() }
    canvas.areAnimationsEnabled = false
    func drag(from start: CGPoint, to end: CGPoint) throws {
      try Self.send(.leftMouseDown, at: start, to: canvas)
      try Self.send(.leftMouseDragged, at: end, to: canvas)
      try Self.send(.leftMouseUp, at: end, to: canvas)
    }
    var samples: [CGPoint] = []
    #expect(canvas.restingCursor === NSCursor.arrow)
    canvas.pointSampling = { samples.append($0) }
    #expect(canvas.restingCursor === NSCursor.crosshair)

    // At the fit, a click over output (200, 100) samples it; a click above
    // the letterboxed output samples nothing.
    for point in [CGPoint(x: 150, y: 150), CGPoint(x: 150, y: 50)] {
      try Self.send(.leftMouseDown, at: point, to: canvas)
      try Self.send(.leftMouseUp, at: point, to: canvas)
    }
    #expect(samples.count == 1)
    #expect(Self.isClose(samples.first, CGPoint(x: 200, y: 100)))

    // Zoomed in to 3, where a drag pans, the click over output (190, 100)
    // samples it, and the drag that follows pans nothing.
    canvas.zoomIn()
    canvas.zoomIn()
    #expect(canvas.restingCursor === NSCursor.crosshair)
    let zoomed = canvas.navigation.position
    try drag(from: CGPoint(x: 120, y: 150), to: CGPoint(x: 90, y: 140))
    #expect(samples.count == 2)
    #expect(Self.isClose(samples.last, CGPoint(x: 190, y: 100)))
    #expect(canvas.navigation.position == zoomed)

    // Without sampling the same drag pans.
    canvas.pointSampling = nil
    #expect(canvas.restingCursor === NSCursor.openHand)
    try drag(from: CGPoint(x: 120, y: 150), to: CGPoint(x: 90, y: 140))
    #expect(samples.count == 2)
    #expect(canvas.navigation.position != zoomed)
    canvas.invalidate()
  }

  // MARK: - Keyboard and VoiceOver

  private enum ArrowKey {
    case left
    case right
    case up
    case down
  }

  /// A key-down of `key` in `window`, as the keyboard sends one, with
  /// `modifiers` besides the ones an arrow key carries.
  private static func keyDown(
    _ key: ArrowKey,
    modifiers: NSEvent.ModifierFlags = [],
    in window: NSWindow
  ) throws -> NSEvent {
    let (characters, keyCode): (String, UInt16) = switch key {
    case .left: ("\u{F702}", 123)
    case .right: ("\u{F703}", 124)
    case .down: ("\u{F701}", 125)
    case .up: ("\u{F700}", 126)
    }
    return try #require(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers.union([.numericPad, .function]),
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
      )
    )
  }

  @Test
  func `Zoomed in, a click gives the canvas the keyboard, and the arrow keys pan it up to the edges`() throws {
    let (canvas, window) = Self.makeLaidOutCanvas()
    defer { window.close() }
    canvas.areAnimationsEnabled = false
    func press(_ key: ArrowKey, _ modifiers: NSEvent.ModifierFlags = []) throws {
      canvas.keyDown(with: try Self.keyDown(key, modifiers: modifiers, in: window))
    }
    func click() throws {
      try Self.send(.leftMouseDown, at: CGPoint(x: 150, y: 150), to: canvas)
      try Self.send(.leftMouseUp, at: CGPoint(x: 150, y: 150), to: canvas)
    }

    // At the fit there is nothing to pan, so a click leaves the keyboard
    // where it is, and Tab passes the canvas by.
    #expect(canvas.acceptsFirstResponder == false)
    #expect(canvas.canBecomeKeyView == false)
    try click()
    #expect(window.firstResponder !== canvas)

    // Zoomed in to 3, a click takes the keyboard; Tab reaches the canvas
    // with Full Keyboard Access on.
    canvas.zoomIn()
    canvas.zoomIn()
    #expect(canvas.acceptsFirstResponder)
    #expect(canvas.canBecomeKeyView == NSApplication.shared.isFullKeyboardAccessEnabled)
    try click()
    #expect(window.firstResponder === canvas)
    #expect(Self.isClose(canvas.navigation.position.center, CGPoint(x: 200, y: 100)))

    // An arrow pans a tenth of the 300-point canvas: 30 points, which move
    // the centre 10 pixels of the output toward the arrow. With Option it
    // pans nine tenths, and it stops at the edge, where the centre's limit
    // is 50.
    try press(.right)
    #expect(Self.isClose(canvas.navigation.position.center, CGPoint(x: 210, y: 100)))
    try press(.down)
    #expect(Self.isClose(canvas.navigation.position.center, CGPoint(x: 210, y: 110)))
    try press(.left, .option)
    #expect(Self.isClose(canvas.navigation.position.center, CGPoint(x: 120, y: 110)))
    try press(.up, .option)
    #expect(Self.isClose(canvas.navigation.position.center, CGPoint(x: 120, y: 50)))
    #expect(canvas.navigation.isMoving == false)
    #expect(Self.forwardedKeyEvents(of: canvas).isEmpty)

    // An arrow with another modifier is passed on.
    try press(.right, .shift)
    #expect(Self.isClose(canvas.navigation.position.center, CGPoint(x: 120, y: 50)))
    #expect(Self.forwardedKeyEvents(of: canvas).count == 1)
    canvas.invalidate()
  }

  /// The rectangle `canvas`'s focus ring mask covers, drawn at a pixel per
  /// point; nil when it draws nothing.
  private static func focusRingMaskCoverage(of canvas: EditingCanvasView) throws -> CGRect? {
    let width = Int(canvas.bounds.width)
    let height = Int(canvas.bounds.height)
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    )
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    canvas.drawFocusRingMask()
    NSGraphicsContext.restoreGraphicsState()

    let pixels = try #require(bitmap.bitmapData)
    var covered: CGRect?
    for y in 0..<height {
      for x in 0..<width where pixels[y * bitmap.bytesPerRow + x * 4 + 3] > 0 {
        covered = (covered ?? CGRect(x: x, y: y, width: 1, height: 1))
          .union(CGRect(x: x, y: y, width: 1, height: 1))
      }
    }
    return covered
  }

  @Test
  func `With Full Keyboard Access, the zoomed canvas's focus ring surrounds a mask 4 points inside its bounds`() throws {
    let (canvas, window) = Self.makeLaidOutCanvas()
    defer { window.close() }
    canvas.areAnimationsEnabled = false
    canvas.isFullKeyboardAccessEnabled = { true }
    // AppKit draws the ring of the first responder around its mask.
    #expect(canvas.focusRingType != .none)

    // At the fit the arrows pan nothing: no mask, so no ring.
    #expect(canvas.focusRingMaskBounds == .zero)
    #expect(try Self.focusRingMaskCoverage(of: canvas) == nil)

    // Zoomed in, the mask is the 300-point canvas 4 points in on every side,
    // so the ring AppKit draws outside it stays inside the canvas.
    canvas.zoomIn()
    #expect(canvas.canBecomeKeyView)
    let mask = CGRect(x: 4, y: 4, width: 292, height: 292)
    #expect(canvas.focusRingMaskBounds == mask)
    #expect(try Self.focusRingMaskCoverage(of: canvas) == mask)

    // The mask follows a resize.
    canvas.frame = CGRect(x: 0, y: 0, width: 360, height: 300)
    canvas.layout()
    #expect(canvas.focusRingMaskBounds == CGRect(x: 4, y: 4, width: 352, height: 292))

    // Back at the fit, the ring goes.
    canvas.zoomToFit()
    #expect(canvas.navigation.isFitted)
    #expect(canvas.focusRingMaskBounds == .zero)
    canvas.invalidate()
  }

  @Test
  func `Without Full Keyboard Access, a click gives the zoomed canvas the keyboard and no focus ring`() throws {
    let (canvas, window) = Self.makeLaidOutCanvas()
    defer { window.close() }
    canvas.areAnimationsEnabled = false
    canvas.isFullKeyboardAccessEnabled = { false }
    canvas.zoomIn()

    try Self.send(.leftMouseDown, at: CGPoint(x: 150, y: 150), to: canvas)
    try Self.send(.leftMouseUp, at: CGPoint(x: 150, y: 150), to: canvas)
    #expect(window.firstResponder === canvas)
    #expect(canvas.canBecomeKeyView == false)
    #expect(canvas.focusRingMaskBounds == .zero)
    #expect(try Self.focusRingMaskCoverage(of: canvas) == nil)
    canvas.invalidate()
  }

  @Test
  func `VoiceOver reads the zoom of the frame on screen as the canvas's value`() throws {
    let canvas = Self.makeCanvas()
    #expect(canvas.accessibilityRole() == .image)
    #expect(canvas.accessibilityValue() == nil)

    let window = Self.makeWindow(containing: canvas)
    defer { window.close() }
    var zooms: [ImageEditorCanvas.Zoom] = []
    canvas.onZoomChange = { zooms.append($0) }
    canvas.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
    canvas.layout()
    canvas.areAnimationsEnabled = false
    let fitted = try #require(zooms.last)
    #expect(canvas.accessibilityValue() as? String == fitted.percent.formatted(.percent))

    canvas.zoomIn()
    let zoomed = try #require(zooms.last)
    #expect(zoomed.percent == 2 * fitted.percent)
    #expect(canvas.accessibilityValue() as? String == zoomed.percent.formatted(.percent))
    canvas.invalidate()
  }

  // MARK: - Content pacing

  @Test
  func `A feature change that keeps the crop is built on the next frame, in the same Metal view`() throws {
    let (canvas, window) = Self.makeLaidOutCanvas()
    defer { window.close() }
    Self.tickUntilPaused(canvas)
    let metalView = try #require(canvas.surface.canvasView)

    var feature = canvas.feature
    feature.effects.exposure = ExposureFeature(ev: 1)
    canvas.setFeature(feature)
    #expect(canvas.needsContentUpdate)
    #expect(canvas.displayLink.isPaused == false)

    // A run of changes waits for the same frame.
    feature.effects.exposure = ExposureFeature(ev: 1.5)
    canvas.setFeature(feature)
    #expect(canvas.needsContentUpdate)

    canvas.drawViewportFrame()
    #expect(canvas.needsContentUpdate == false)
    #expect(canvas.surface.canvasView === metalView)
    #expect(canvas.surface.displayedViewport != nil)
    canvas.invalidate()
  }

  @Test
  func `A crop change is built at once, drawn at once in a Metal view of a new size, and fitted`() throws {
    let (canvas, window) = Self.makeLaidOutCanvas()
    defer { window.close() }
    canvas.areAnimationsEnabled = false
    canvas.zoomIn()
    canvas.zoomIn()
    let metalView = try #require(canvas.surface.canvasView)

    // A square crop: a new output size, in a Metal view of its own, which
    // fits at 1.5.
    var feature = canvas.feature
    feature.crop = CropFeature(rect: CGRect(x: 0, y: 0, width: 200, height: 200))
    canvas.setFeature(feature)
    #expect(canvas.needsContentUpdate == false)
    #expect(canvas.outputGeometry?.outputSize == CGSize(width: 200, height: 200))
    let squareView = try #require(canvas.surface.canvasView)
    #expect(squareView !== metalView)
    #expect(squareView.hasRenderImages)
    let viewport = try #require(canvas.surface.displayedViewport)
    #expect(canvas.navigation.isFitted)
    #expect(Self.isClose(viewport.contentToCanvasTransform.a, 1.5))

    // A crop of the same size keeps the Metal view and the zoom.
    canvas.zoomIn()
    let zoomed = canvas.navigation.position.scale
    feature.crop = CropFeature(rect: CGRect(x: 100, y: 0, width: 200, height: 200))
    canvas.setFeature(feature)
    #expect(canvas.needsContentUpdate == false)
    #expect(canvas.surface.canvasView === squareView)
    #expect(canvas.navigation.position.scale == zoomed)
    canvas.invalidate()
  }
}
#endif
