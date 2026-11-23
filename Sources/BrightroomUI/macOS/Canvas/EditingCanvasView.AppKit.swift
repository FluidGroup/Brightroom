// The AppKit counterpart of EditingCanvasView.swift. It has the same type
// name, because it is the platform's canvas view, and a `.AppKit` file name
// suffix because one module cannot contain two files with the same name.

#if os(macOS)
import AppKit
import BrightroomEngine
import BrightroomParametric
import QuartzCore

/// An AppKit canvas that shows an `ImageEditorFeature`'s output with zoom and
/// pan: value in. It views only; crop editing and the brush are not on macOS
/// yet. It composes the pieces the UIKit canvas's tool surface is built from:
/// `CanvasMetalSurface` draws, `CanvasNavigation` decides the viewport.
///
/// The content is the feature's crop output (effects, local blur and crop),
/// fitted to the view, with the post-crop pass (the vignette) drawn over it
/// each frame. The trackpad and the mouse zoom and pan it: scrolling pans
/// once zoomed in, and is left to the surrounding views at the fit; a pinch,
/// a Command-scroll and a smart-magnify double tap zoom.
///
/// Frames run from a display link that pauses while nothing moves, and that
/// input, layout, a feature change and window changes resume. Call
/// `invalidate()` when the view is dismantled; the view also invalidates the
/// link when it is deallocated.
final class EditingCanvasView: NSView, ViewportDisplayLinkOwner {

  /// What a run of scroll events does, decided when a gesture begins and kept
  /// for the gesture and its momentum.
  private enum ScrollMode {
    /// The content moves.
    case navigate
    /// The content zooms about the pointer (Command held).
    case zoom
    /// The surrounding views receive the events (nothing to scroll).
    case forward
  }

  /// Canvas points per line of a mouse wheel that reports lines, the line
  /// scroll `NSScrollView` uses by default.
  private static let lineHeight: CGFloat = 10

  /// The zoom per point of a Command-scroll on a trackpad (precise deltas),
  /// as the exponent of the zoom factor.
  private static let preciseZoomRate: CGFloat = 0.01

  /// The zoom per line of a Command-scroll on a mouse wheel, as the exponent
  /// of the zoom factor.
  private static let lineZoomRate: CGFloat = 0.1

  let source: EditingCanvasSource

  private(set) var feature: ImageEditorFeature

  /// Whether the navigation animates the motions it starts. When this is
  /// false, or when the user asks the system to reduce motion, the way back
  /// from a rubber band and a zoom toggle complete at once, and momentum
  /// stops at an edge instead of bouncing.
  var areAnimationsEnabled = true

  /// Draws the frames. Internal so tests can read what it shows.
  let surface = CanvasMetalSurface()

  /// The zoom and pan. Internal (read-only) so tests can read it.
  private(set) var navigation = CanvasNavigation(contentSize: .zero, canvasSize: .zero)

  /// The crop output the canvas shows, or nil when the feature has none.
  private(set) var outputGeometry: EditingCanvasCropOutputGeometry?

  /// Drives the frames. Internal so tests can read whether it is paused or
  /// scheduled.
  let displayLink = ViewportDisplayLink()
  private var renderInputKey: CanvasRenderInputKey?
  private var committedStrokeRecords = CommittedStrokeRecords()
  private var scrollMode: ScrollMode?
  /// Whether the `.mayBegin` of the current touch was passed on and the
  /// surrounding views have neither taken its gesture nor been passed its
  /// end. The views that saw a touch start see it end, even when the canvas
  /// takes its gesture.
  private var hasForwardedMayBegin = false
  /// Whether a pinch has begun and not ended. Fingers that land anew
  /// (`.mayBegin`) clear it too: a pinch whose end never arrived is over
  /// then.
  private var isMagnifying = false
  private var isInvalidated = false

  /// Whether the editing target the host asked for has been reported as not
  /// supported on macOS.
  private var hasReportedEditingTarget = false

  init(source: EditingCanvasSource, feature: ImageEditorFeature) {
    self.source = source
    self.feature = feature
    super.init(frame: .zero)
    wantsLayer = true
    layer?.isOpaque = false
    displayLink.owner = self
    setAccessibilityElement(true)
    setAccessibilityRole(.image)
    updateContent()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  isolated deinit {
    // A paused link gets no ticks, so it cannot notice that this view is gone.
    displayLink.invalidate()
  }

  // MARK: - Inputs

  /// Shows `feature`. The zoom and pan are kept unless the crop output
  /// changes size, which shows the new output fitted.
  func setFeature(_ feature: ImageEditorFeature) {
    guard feature != self.feature else { return }
    self.feature = feature
    updateContent()
    // Drawn now, like a layout, so a Metal view that `updateContent()`
    // replaced presents in this transaction rather than a tick later.
    drawFrame()
    requestFrames()
  }

  /// Builds the render images with `rendering`'s calculations, as an export
  /// passed the same selection renders them.
  func setAdjustmentRendering(_ rendering: AdjustmentRendering) {
    guard surface.adjustmentRendering != rendering else { return }
    surface.adjustmentRendering = rendering
    updateContent()
    drawFrame()
    requestFrames()
  }

  /// Reports, once per canvas, that the canvas does not edit `target` on
  /// macOS and shows the output instead. The log is written in debug builds
  /// only (`EditorLog`).
  func reportEditingTarget(_ target: ImageEditorCanvas.Target?) {
    guard let target, hasReportedEditingTarget == false else { return }
    hasReportedEditingTarget = true
    EditorLog.debug(.editingCanvas, """
      ImageEditorCanvas does not edit \(target) on macOS yet; it shows the output. \
      Use .editingTarget(nil) to ask for a viewer.
      """)
  }

  /// Stops the display link for good. Call it when the view is dismantled.
  func invalidate() {
    isInvalidated = true
    displayLink.invalidate()
  }

  // MARK: - NSView

  override var isFlipped: Bool { true }

  override var isOpaque: Bool { false }

  override func layout() {
    super.layout()
    surface.canvasView?.frame = bounds
    navigation.setCanvasSize(bounds.size)
    // The Metal view presents with the Core Animation transaction, so drawing
    // here commits the frame with the new size and a resize never shows a
    // stretched one.
    drawFrame()
    requestFrames()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    NotificationCenter.default.removeObserver(
      self, name: NSWindow.didChangeScreenNotification, object: nil
    )
    guard let window else {
      displayLink.isPaused = true
      surface.canvasView?.releasePreFinishCache()
      return
    }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowDidChangeScreen(_:)),
      name: NSWindow.didChangeScreenNotification,
      object: window
    )
    startDisplayLink()
    surface.canvasView?.setNeedsCanvasDisplay()
    needsLayout = true
    requestFrames()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    refreshForScreen()
  }

  @objc private func windowDidChangeScreen(_ notification: Notification) {
    refreshForScreen()
  }

  // MARK: - Events

  override func scrollWheel(with event: NSEvent) {
    if event.phase.contains(.mayBegin) {
      // Fingers rest on the trackpad: a new gesture may follow, and a pinch
      // whose end never arrived is over.
      scrollMode = nil
      isMagnifying = false
      handle(.touchDown, at: inputTime(of: event))
      // With nothing to scroll, the surrounding views may take the gesture,
      // so they see its start too (to stop their own momentum, for example).
      hasForwardedMayBegin =
        navigation.canScroll == false && event.modifierFlags.contains(.command) == false
      if hasForwardedMayBegin {
        super.scrollWheel(with: event)
      }
      return
    }

    // A legacy wheel event (no phases) decides its mode on its own.
    if event.phase.isEmpty, event.momentumPhase.isEmpty {
      switch decideScrollMode(for: event, allowsZoom: true) {
      case .forward:
        super.scrollWheel(with: event)
      case .zoom:
        zoom(by: event)
      case .navigate:
        handle(
          .scroll(translation: wheelTranslation(of: event), source: .wheel),
          at: inputTime(of: event)
        )
      }
      return
    }

    if event.phase.contains(.began) {
      scrollMode = decideScrollMode(for: event, allowsZoom: true)
    } else if scrollMode == nil {
      // An end with no gesture begun (a touch lifted without moving) only
      // ends the navigation's gesture: that is harmless, and settles a
      // motion `touchDown` stopped. A touch that turned into a pinch is
      // cancelled while the pinch holds the zoom, and the pinch ends the
      // gesture itself. The surrounding views get the end when they got the
      // touch's `.mayBegin`.
      if isEnding(event) {
        if isMagnifying == false {
          handle(.gestureEnded(velocity: nil), at: inputTime(of: event))
        }
        if hasForwardedMayBegin {
          hasForwardedMayBegin = false
          super.scrollWheel(with: event)
        }
        return
      }
      // A gesture or momentum whose beginning this view did not see. Momentum
      // never zooms.
      scrollMode = decideScrollMode(
        for: event, allowsZoom: event.momentumPhase.isEmpty
      )
    }

    let mode = scrollMode
    if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
      // The gesture and its momentum are over.
      scrollMode = nil
    }

    switch mode {
    case .forward:
      // The surrounding views take this gesture, so for the navigation the
      // touch is over: a motion the touch stopped, such as a zoom on its way
      // back to the fit, goes on. Not from the beginning of a gesture whose
      // fingers hold a pinch, which keeps its zoom. Its end always counts:
      // the fingers have lifted, even if the pinch's own end got lost.
      if isEnding(event) || (event.phase.contains(.began) && isMagnifying == false) {
        handle(.gestureEnded(velocity: nil), at: inputTime(of: event))
      }
      hasForwardedMayBegin = false
      super.scrollWheel(with: event)
    case .zoom:
      // Momentum is ignored while zooming, and a stepped zoom needs no end.
      if event.phase.contains(.began) || event.phase.contains(.changed) {
        zoom(by: event)
      }
      forwardEndOfForwardedTouch(event)
    case .navigate:
      navigate(with: event)
      forwardEndOfForwardedTouch(event)
    case nil:
      break
    }
  }

  override func magnify(with event: NSEvent) {
    let anchor = convert(event.locationInWindow, from: nil)
    // `magnification` is a delta to add to the current scale; the canvas
    // multiplies by its exponential instead, so a pinch zooms at the same
    // speed at every zoom and never by a non-positive factor.
    let factor = exp(event.magnification)
    let time = inputTime(of: event)
    if event.phase.isEmpty {
      handle(.zoomStep(factor: factor, anchor: anchor), at: time)
    } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
      isMagnifying = false
      handle(.gestureEnded(velocity: nil), at: time)
    } else if event.phase.contains(.began) || event.phase.contains(.changed) {
      isMagnifying = true
      handle(.magnify(factor: factor, anchor: anchor), at: time)
    }
  }

  override func smartMagnify(with event: NSEvent) {
    handle(
      .toggleZoom(anchor: convert(event.locationInWindow, from: nil)),
      at: inputTime(of: event)
    )
  }

  // MARK: - ViewportDisplayLinkOwner

  func drawViewportFrame() {
    navigation.advance(to: CACurrentMediaTime())
    if drawFrame() == false {
      displayLink.isPaused = true
    }
  }

  // MARK: - Private

  /// Builds what the canvas shows from the feature: the crop output's render
  /// images and committed strokes, through the same shared calls as the
  /// UIKit canvas's tool surface.
  private func updateContent() {
    let crop = CropGuideState(cropFeature: feature.crop, imageSize: source.imageSize)
    guard
      let geometry = EditingCanvasCropOutputGeometry(crop: crop),
      ensureCanvasView(canvasSize: geometry.outputSize) != nil
    else {
      outputGeometry = nil
      renderInputKey = nil
      surface.removeCanvasView()
      return
    }

    surface.updateCropOutput(
      source: source,
      effects: feature.effects,
      geometry: geometry,
      mode: CanvasRenderPlan(localBlur: feature.localBlur).canvasMode,
      committedStrokes: committedStrokeRecords.outputRecords(
        localBlur: feature.localBlur,
        geometry: geometry,
        domainHeight: source.imageSize.height
      ),
      key: &renderInputKey
    )
    outputGeometry = geometry
    // Fits new content; content of the same size keeps the zoom and pan.
    navigation.setContentSize(geometry.outputSize)
  }

  /// The Metal canvas view for content of `canvasSize`. The canvas takes no
  /// brush input on macOS yet, so the brush it is configured with never
  /// draws, and a stroke commit (which cannot happen) only completes.
  private func ensureCanvasView(canvasSize: CGSize) -> EditingCanvasMTKView? {
    surface.ensureCanvasView(
      in: self,
      canvasSize: canvasSize,
      brush: EditingCanvasBrush(),
      smoothing: .off,
      onStrokeCommit: { _, completion in completion() }
    )
  }

  /// Draws the current viewport if it changed. Returns whether frames should
  /// keep running: a motion is under way or a frame is still to be presented.
  /// Draws nothing, and returns false, without a window or with nothing to
  /// show (no crop output, or a canvas with no size).
  @discardableResult
  private func drawFrame() -> Bool {
    guard
      let window,
      let geometry = outputGeometry,
      let canvasView = surface.canvasView
    else {
      return false
    }
    let viewport = navigation.viewport(contentScaleFactor: window.backingScaleFactor)
    surface.draw(
      viewport: viewport,
      postCrop: viewport.flatMap {
        CanvasPostCrop(effect: feature.canvasPostCropEffect, geometry: geometry, viewport: $0)
      }
    )
    guard viewport != nil else { return false }
    return navigation.isMoving || canvasView.hasPendingDisplay
  }

  /// Resumes the display link, if the view is in a window.
  private func requestFrames() {
    guard isInvalidated == false, window != nil else { return }
    displayLink.isPaused = false
  }

  private func startDisplayLink() {
    guard isInvalidated == false, let window else { return }
    displayLink.start(
      in: self,
      maximumFramesPerSecond: EditingCanvasMTKView.targetFrameRate(for: window.screen)
    )
  }

  /// Follows a change of screen or backing scale: the frame rate, and a new
  /// frame at the new scale.
  private func refreshForScreen() {
    guard window != nil else { return }
    startDisplayLink()
    surface.canvasView?.refreshFrameRate()
    surface.canvasView?.setNeedsCanvasDisplay()
    drawFrame()
    requestFrames()
  }

  private func handle(_ input: CanvasNavigation.Input, at time: TimeInterval) {
    navigation.animates = areAnimationsEnabled
      && NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false
    navigation.handle(input, at: time)
    requestFrames()
  }

  /// The time `event` happened, on the clock of `CACurrentMediaTime()`, which
  /// an event's timestamp shares. The navigation measures how fast the
  /// content moves from these times, so it gets when the input happened and
  /// not when the main thread came to it.
  private func inputTime(of event: NSEvent) -> TimeInterval {
    Self.inputTime(timestamp: event.timestamp, now: CACurrentMediaTime())
  }

  /// The time of an event stamped `timestamp` that is handled at `now`: the
  /// timestamp when it is plausible, from half a second ago to a moment
  /// ahead, and `now` otherwise (an event made in code carries none).
  /// Internal so tests can check the rule.
  static func inputTime(timestamp: TimeInterval, now: TimeInterval) -> TimeInterval {
    let age = now - timestamp
    return timestamp > 0 && age > -0.005 && age < 0.5 ? timestamp : now
  }

  private func decideScrollMode(for event: NSEvent, allowsZoom: Bool) -> ScrollMode {
    if allowsZoom, event.modifierFlags.contains(.command) {
      return .zoom
    }
    return navigation.canScroll ? .navigate : .forward
  }

  private func isEnding(_ event: NSEvent) -> Bool {
    event.phase.contains(.ended) || event.phase.contains(.cancelled)
      || event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled)
  }

  /// Passes on the end of a gesture the canvas took, when the surrounding
  /// views saw its touch start: the fingers rested while there was nothing
  /// to scroll, and the gesture then zoomed or found something to scroll.
  private func forwardEndOfForwardedTouch(_ event: NSEvent) {
    guard
      hasForwardedMayBegin,
      event.phase.contains(.ended) || event.phase.contains(.cancelled)
    else {
      return
    }
    hasForwardedMayBegin = false
    super.scrollWheel(with: event)
  }

  private func navigate(with event: NSEvent) {
    let translation = CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY)
    let time = inputTime(of: event)
    // The system sends the momentum after a gesture itself, so an end gives
    // no velocity to decelerate from.
    if event.phase.contains(.began) || event.phase.contains(.changed) {
      handle(.scroll(translation: translation, source: .gesture), at: time)
    } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
      handle(.gestureEnded(velocity: nil), at: time)
    } else if event.momentumPhase.contains(.began) || event.momentumPhase.contains(.changed) {
      handle(.scroll(translation: translation, source: .momentum), at: time)
    } else if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
      handle(.gestureEnded(velocity: nil), at: time)
    }
  }

  /// The translation of a legacy wheel event in canvas points.
  private func wheelTranslation(of event: NSEvent) -> CGSize {
    let scale = event.hasPreciseScrollingDeltas ? 1 : Self.lineHeight
    return CGSize(width: event.scrollingDeltaX * scale, height: event.scrollingDeltaY * scale)
  }

  /// Zooms about the pointer for a Command-scroll. Moving the fingers or the
  /// wheel away from the user zooms in, whatever the scroll direction setting.
  private func zoom(by event: NSEvent) {
    // `scrollingDeltaY` includes the natural-scrolling inversion; undo it to
    // get the direction the device moved.
    let deviceDelta = event.isDirectionInvertedFromDevice
      ? -event.scrollingDeltaY
      : event.scrollingDeltaY
    let rate = event.hasPreciseScrollingDeltas ? Self.preciseZoomRate : Self.lineZoomRate
    handle(
      .zoomStep(
        factor: exp(deviceDelta * rate),
        anchor: convert(event.locationInWindow, from: nil)
      ),
      at: inputTime(of: event)
    )
  }
}
#endif
