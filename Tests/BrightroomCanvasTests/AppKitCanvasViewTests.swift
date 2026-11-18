#if os(macOS)
import AppKit
import BrightroomParametric
import CoreImage
import Metal
import Testing

@testable import BrightroomUI

/// The AppKit `EditingCanvasView` on its own: its lifecycle at zero size and
/// outside a window, its first frame, its display link, and how it reads and
/// passes on scroll events.
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

  /// A superview that records the scroll events passed on to it.
  final class ScrollRecordingView: NSView {
    private(set) var receivedScrollEvents: [NSEvent] = []

    override func scrollWheel(with event: NSEvent) {
      receivedScrollEvents.append(event)
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
    let container = ScrollRecordingView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
    window.contentView = container
    container.addSubview(view)
    return window
  }

  /// The scroll events the canvas's superview received.
  private static func forwardedScrollEvents(of canvas: EditingCanvasView) -> [NSEvent] {
    (canvas.superview as? ScrollRecordingView)?.receivedScrollEvents ?? []
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
}
#endif
