import CoreGraphics
import Foundation
import struct SwiftUI.Spring

/// The zoom and pan of a canvas over rectangular content, as a value.
///
/// This is what a scroll view otherwise provides: the fit, the zoom limits,
/// the rubber band past them, the bounce at a limit, the deceleration after
/// the fingers lift, and the motion back inside. It owns no view and reads no
/// clock. A host passes input and the time, and reads `viewport` to draw, so
/// a host whose system sends momentum (AppKit) and one that gets a velocity
/// when the fingers lift (UIKit) show the same behavior.
///
/// The centre's two axes and the zoom move separately, each as a closed form
/// of time (`AxisMotion`, `SpringBack`), so `advance(to:)` answers for any
/// time, however many frames a host drew since the motion started. SwiftUI's
/// `Spring` computes the springs.
///
/// It navigates content that fills a rectangle inside a rectangular canvas:
/// the crop output on a tool surface. Navigating under a crop guide, where
/// the image turns and the guide is not the canvas, needs a different
/// constraint and is not this type.
///
/// Content and canvas use top-left, y-down coordinates, as `CanvasViewport`
/// does. The content is `contentSize` in its own units (the crop output's
/// pixels on a tool surface); the canvas is `canvasSize` in points. Times are
/// seconds on one clock for input and frames, such as `CACurrentMediaTime()`.
/// An input's time is when it happened (an event's timestamp), which can be a
/// little earlier than the last frame's time.
///
/// To draw a tool's input where the user sees it, map points through the
/// `CanvasViewport` of the frame on screen, not through this value: input may
/// have moved the navigation ahead of that frame.
struct CanvasNavigation: Equatable, Sendable {

  /// A zoom and the content point shown at the canvas centre.
  struct Position: Equatable, Sendable {
    /// Canvas points per content unit.
    var scale: CGFloat
    /// The content point at the centre of the canvas.
    var center: CGPoint
  }

  /// An axis of the canvas.
  enum Axis: CaseIterable, Equatable, Sendable {
    case horizontal
    case vertical
  }

  /// A value for each axis.
  struct PerAxis<Value: Equatable & Sendable>: Equatable, Sendable {
    var horizontal: Value
    var vertical: Value

    init(horizontal: Value, vertical: Value) {
      self.horizontal = horizontal
      self.vertical = vertical
    }

    /// The same value on both axes.
    init(_ value: Value) {
      self.init(horizontal: value, vertical: value)
    }

    subscript(axis: Axis) -> Value {
      get {
        switch axis {
        case .horizontal: horizontal
        case .vertical: vertical
        }
      }
      set {
        switch axis {
        case .horizontal: horizontal = newValue
        case .vertical: vertical = newValue
        }
      }
    }
  }

  /// Where a scroll translation comes from, which decides what happens at a
  /// limit.
  enum ScrollSource: Equatable, Sendable {
    /// Fingers move the content: past a limit it rubber-bands.
    case gesture
    /// The system's momentum after a gesture: at a limit it bounces, keeping
    /// its speed. Content that the fingers left past a limit it takes back
    /// inside and on, when it points that way and carries that far. Each
    /// axis follows it on its own.
    case momentum
    /// A stepped device such as a mouse wheel: it stops at a limit.
    case wheel
  }

  /// What a host reports. Translations and anchors are in canvas points, and
  /// velocities in canvas points per second, signed like a translation
  /// (positive moves the content right or down).
  ///
  /// A gesture is any run of `scroll(source: .gesture)` and `magnify`,
  /// interleaved freely (a pinch that also moves sends both), closed by one
  /// `gestureEnded`. Sending `gestureEnded` again, or with no gesture open,
  /// is harmless.
  enum Input: Equatable, Sendable {
    /// Fingers rest on the input device: a running motion stops where it is,
    /// and a gesture that is still open is closed. Send it once, when the
    /// first finger lands (in UIKit, `touchesBegan` with no other touch
    /// down), and `gestureEnded` when the last one lifts, whether or not a
    /// gesture began, so that content stopped past a limit moves back inside.
    case touchDown
    /// The content moves by `translation` on the canvas.
    case scroll(translation: CGSize, source: ScrollSource)
    /// A pinch scales the content by `factor`, keeping the content under
    /// `anchor` in place. Past a zoom limit it rubber-bands.
    case magnify(factor: CGFloat, anchor: CGPoint)
    /// The gesture, or the momentum that followed it, ended: whatever is past
    /// a limit moves back inside.
    ///
    /// - Parameter velocity: Nil when the system continues the motion itself
    ///   (AppKit sends its momentum as scroll events, so the AppKit canvas
    ///   passes nil). Otherwise the fingers' velocity, as
    ///   `UIPanGestureRecognizer.velocity(in:)` reports it, and `.zero` when
    ///   there is none: the content decelerates on from it. From past a
    ///   limit it does so when the velocity carries it back inside;
    ///   otherwise the velocity sets how fast the content starts back. Pass
    ///   it unchanged: the navigation drops it when the fingers had stopped
    ///   before they lifted and after a gesture that pinched, and slows it
    ///   as the rubber band does past a limit.
    case gestureEnded(velocity: CGSize?)
    /// A stepped zoom, such as a mouse wheel with a modifier key: it stops at
    /// a zoom limit and needs no end.
    case zoomStep(factor: CGFloat, anchor: CGPoint)
    /// Switches between the fit and a closer look at `anchor`, with the
    /// settle spring. It takes over a running motion from what is shown,
    /// keeping its velocity, and stops momentum.
    case toggleZoom(anchor: CGPoint)
    /// Zooms to `scale`, clamped to the limits, keeping the content under
    /// `anchor` in place as far as the limits allow (the canvas centre when
    /// nil): with the settle spring when `animated` and `animates` allow, as
    /// `toggleZoom` does, and at once otherwise. Stops momentum.
    case zoom(scale: CGFloat, anchor: CGPoint?, animated: Bool)
  }

  /// The largest zoom, as a multiple of the fit.
  static let maximumZoomFactor: CGFloat = 8

  /// The zoom `toggleZoom` goes to from the fit, as a multiple of the fit.
  static let toggledZoomFactor: CGFloat = 3

  /// How much of a pull past a limit is shown; the value scroll views use.
  static let rubberBandCoefficient: CGFloat = 0.55

  /// The spring of a motion that reaches a limit at speed: it starts at the
  /// limit with that speed, goes past, and comes back. Critically damped,
  /// with a stiffness of 100 for a mass of 1, which moves like a scroll
  /// view's bounce.
  static let bounceSpring = Spring(response: 2 * .pi / 10, dampingRatio: 1)

  /// The spring that brings what is released to its rest: the way back from
  /// past a limit, a zoom that settles inside its limits, a zoom toggle.
  /// Critically damped and stiffer than `bounceSpring`.
  static let settleSpring = Spring(response: 0.4, dampingRatio: 1)

  /// How close to its rest a spring counts as there, in canvas points.
  static let restingDistance: CGFloat = 0.25

  /// How close to its destination a deceleration ends, in canvas points.
  static let decelerationEndDistance: CGFloat = 0.5

  /// The most a spring's velocity carries it, as a share of the room it has
  /// on the canvas along that axis: the whole canvas for one that leaves a
  /// limit or comes in toward it, what is left of the canvas for one that
  /// moves farther out from past the limit. A faster motion gets a stiffer
  /// spring instead of going farther, so the content never leaves the canvas.
  static let maximumOvershootFraction: CGFloat = 0.5

  /// A gesture that ends this many seconds after its last movement ends at
  /// rest: its fingers had stopped.
  static let stillnessInterval: TimeInterval = 0.1

  /// The content's size in its own units.
  private(set) var contentSize: CGSize

  /// The canvas's size in points.
  private(set) var canvasSize: CGSize

  /// The canvas points the fit leaves clear around the content on every
  /// side. Zoomed in, the content reaches the canvas's edges.
  private(set) var fitMargin: CGFloat = 0

  /// When false, a motion that would start (the way back from a rubber band,
  /// a bounce, a zoom toggle) completes at once instead, and nothing
  /// decelerates. A motion that is already running runs on.
  var animates = true

  /// The share of its velocity a deceleration keeps each millisecond, above
  /// 0 and below 1; another value is not taken. 0.998 is
  /// `UIScrollView.DecelerationRate.normal`; `.fast` is 0.99. It applies to
  /// a gesture that ends with a velocity.
  var decelerationRate: CGFloat = 0.998 {
    didSet {
      if (decelerationRate > 0 && decelerationRate < 1) == false {
        decelerationRate = oldValue
      }
    }
  }

  /// What the canvas shows now.
  private(set) var position: Position

  /// Where input has driven the position, before the rubber band. It equals
  /// `position` inside the limits while nothing moves. A moving component's
  /// is not read: it is set from what is shown when the motion is
  /// interrupted or ends.
  private var tracked: Position

  private var motion = Motion()

  /// The latest time motions were moved to. It never runs backwards.
  private var clock: TimeInterval?

  /// The velocity of the gesture and momentum scrolls, measured from their
  /// own times.
  private var velocityEstimate = VelocityEstimate()

  /// The time of the open gesture's last scroll or pinch; nil once the
  /// gesture has ended.
  private var lastMovementTime: TimeInterval?

  /// The time of the previous gesture or momentum scroll since the last
  /// touch, pinch, zoom, wheel, resize or reset.
  private var lastScrollTime: TimeInterval?

  /// Per axis, set while the momentum the system still sends must not move
  /// that axis: momentum reached its limit, or pointed farther out from past
  /// it, or could not bring the axis back inside (or animation is off); a
  /// gesture left the axis away from its rest with fingers that were at
  /// rest, with a velocity the host gave, or on an axis the content fits
  /// on; or a touch, a pinch or a zoom took over. A gesture that begins and
  /// a reset clear it, and so does the end of a gesture that leaves the
  /// axis past its limit with moving fingers, where the system's momentum
  /// follows.
  ///
  /// While it is clear, a spring on that axis is its way back from past a
  /// limit, and momentum that points back inside may take the axis over
  /// from it.
  private var ignoresMomentum = PerAxis(false)

  private var isGestureOpen = false

  /// Whether the open gesture, or the last one, pinched. Nothing
  /// decelerates after a pinch.
  private var didPinch = false

  /// Where the open gesture last pinched.
  private var zoomAnchor: CGPoint?

  /// Starts fitted: the whole content, centred.
  init(contentSize: CGSize, canvasSize: CGSize) {
    self.contentSize = contentSize
    self.canvasSize = canvasSize
    let fitted = Self.fittedPosition(
      contentSize: contentSize, canvasSize: canvasSize, margin: fitMargin
    )
    self.position = fitted
    self.tracked = fitted
  }

  // MARK: - Layout

  /// The zoom at which the whole content fits the canvas inside the fit
  /// margin; 0 while the content or that room has no size, or the sizes are
  /// too extreme to compute a zoom with.
  var fitScale: CGFloat {
    Self.fitScale(contentSize: contentSize, canvasSize: canvasSize, margin: fitMargin)
  }

  /// The zoom limits: from the fit to `maximumZoomFactor` times the fit.
  var scaleRange: ClosedRange<CGFloat> {
    let fit = fitScale
    return fit...(fit * Self.maximumZoomFactor)
  }

  /// Whether the canvas shows the fit.
  var isFitted: Bool {
    let fit = fitScale
    return abs(position.scale - fit) <= 1e-6 * max(fit, .leastNonzeroMagnitude)
  }

  /// The zoom a running zoom motion settles at, else the current zoom, so
  /// consecutive steps compound.
  var targetScale: CGFloat {
    motion.zoom?.rest ?? position.scale
  }

  /// Whether a motion is running, so the host keeps drawing frames.
  var isMoving: Bool {
    motion.zoom != nil || motion.center.horizontal != nil || motion.center.vertical != nil
  }

  /// Whether scrolling can move the content at the current zoom. At the fit
  /// it cannot, so a host can leave such a scroll to its surroundings.
  var canScroll: Bool {
    Axis.allCases.contains { centerRange(along: $0, scale: position.scale) != nil }
  }

  /// Follows a canvas resize, stopping any motion. A fitted canvas stays
  /// fitted; otherwise the zoom and the centre are kept as far as the new
  /// limits allow.
  mutating func setCanvasSize(_ size: CGSize) {
    guard size != canvasSize else { return }
    let wasFitted = isFitted
    canvasSize = size
    followFitChange(wasFitted: wasFitted)
  }

  /// Leaves `margin` canvas points clear around the content at the fit,
  /// following the change as a resize does.
  mutating func setFitMargin(_ margin: CGFloat) {
    guard margin != fitMargin else { return }
    let wasFitted = isFitted
    fitMargin = margin
    followFitChange(wasFitted: wasFitted)
  }

  /// Shows new content, fitted.
  mutating func setContentSize(_ size: CGSize) {
    guard size != contentSize else { return }
    contentSize = size
    reset()
  }

  /// Returns to the fit without animation.
  mutating func reset() {
    motion = Motion()
    forgetVelocity()
    ignoresMomentum = PerAxis(false)
    isGestureOpen = false
    didPinch = false
    zoomAnchor = nil
    position = Self.fittedPosition(
      contentSize: contentSize, canvasSize: canvasSize, margin: fitMargin
    )
    tracked = position
  }

  // MARK: - Input

  /// Applies `input`, after moving running motions to `time`, which is on
  /// the clock `advance(to:)` uses. A host passes a finite time.
  mutating func handle(_ input: Input, at time: TimeInterval) {
    // A time that is not finite is no time: the input happens at the latest
    // time given.
    guard time.isFinite else {
      handle(input, at: clock ?? 0)
      return
    }
    advance(to: time)
    // Motions start on the motion clock, so what is shown never jumps when an
    // input's time is behind it. Velocities are measured by the inputs' own
    // times.
    let now = clock ?? time

    switch input {
    case .touchDown:
      interrupt()
      isGestureOpen = false
      forgetVelocity()
      // Momentum that still arrives belongs to the motion the touch stopped.
      ignoresMomentum = PerAxis(true)

    case let .scroll(translation, source):
      switch source {
      case .gesture:
        openGesture()
        interrupt()
        velocityEstimate.add(scroll(by: translation, stopsAtLimits: false), at: time)
        lastMovementTime = time
        lastScrollTime = time
      case .momentum:
        followMomentum(translation, at: time, now: now)
      case .wheel:
        interrupt()
        forgetVelocity()
        // A wheel has no end that would bring back what it stopped past a
        // limit, the zoom included, so that goes to its rest now.
        if scaleRange.lowerBound > 0 {
          position = restingPosition(near: position)
          tracked = position
        }
        scroll(by: translation, stopsAtLimits: true)
      }

    case let .gestureEnded(velocity):
      endGesture(velocity: velocity, at: time, now: now)

    case let .magnify(factor, anchor):
      openGesture()
      interrupt()
      ignoresMomentum = PerAxis(true)
      didPinch = true
      // A pinch's movement says nothing about how fast the content pans.
      forgetVelocity()
      lastMovementTime = time
      let range = scaleRange
      guard
        factor.isFinite, factor > 0, anchor.x.isFinite, anchor.y.isFinite,
        range.lowerBound > 0
      else {
        return
      }
      zoomAnchor = anchor
      // What is already shown past a limit: a pan in this gesture, or a
      // motion back that this pinch stopped.
      let pullBefore = shownPull(of: position)
      // Bounded so a long pinch past a limit does not have to be undone at
      // length before the content responds again.
      tracked.scale = min(
        max(tracked.scale * factor, range.lowerBound / 16),
        range.upperBound * 16
      )
      let scale = shownScale(forTracked: tracked.scale)
      let placed = center(keeping: anchor, atScale: scale)
      position = Position(
        scale: scale,
        center: CGPoint(
          x: Self.pinchedCenter(
            placed.x, keeping: pullBefore.width,
            content: contentSize.width, canvas: canvasSize.width, scale: scale
          ),
          y: Self.pinchedCenter(
            placed.y, keeping: pullBefore.height,
            content: contentSize.height, canvas: canvasSize.height, scale: scale
          )
        )
      )
      tracked.center = trackedPosition(showing: position).center

    case let .zoomStep(factor, anchor):
      interrupt()
      ignoresMomentum = PerAxis(true)
      forgetVelocity()
      let range = scaleRange
      guard
        factor.isFinite, factor > 0, anchor.x.isFinite, anchor.y.isFinite,
        range.lowerBound > 0
      else {
        return
      }
      let scale = min(max(position.scale * factor, range.lowerBound), range.upperBound)
      position = Position(
        scale: scale,
        center: restingCenter(center(keeping: anchor, atScale: scale), scale: scale)
      )
      tracked = position

    case let .toggleZoom(anchor):
      let running = motion
      interrupt()
      ignoresMomentum = PerAxis(true)
      forgetVelocity()
      let range = scaleRange
      guard anchor.x.isFinite, anchor.y.isFinite, range.lowerBound > 0 else { return }
      let scale = isFitted
        ? min(range.lowerBound * Self.toggledZoomFactor, range.upperBound)
        : range.lowerBound
      startZoomMotion(
        to: Position(
          scale: scale,
          center: restingCenter(center(keeping: anchor, atScale: scale), scale: scale)
        ),
        continuing: running,
        at: now
      )

    case let .zoom(scale, anchor, animated):
      let running = motion
      interrupt()
      ignoresMomentum = PerAxis(true)
      forgetVelocity()
      let range = scaleRange
      let anchor = anchor ?? CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
      guard
        scale.isFinite, scale > 0, anchor.x.isFinite, anchor.y.isFinite,
        range.lowerBound > 0
      else {
        return
      }
      let scale = min(max(scale, range.lowerBound), range.upperBound)
      let target = Position(
        scale: scale,
        center: restingCenter(center(keeping: anchor, atScale: scale), scale: scale)
      )
      if animated {
        startZoomMotion(to: target, continuing: running, at: now)
      } else {
        position = target
        tracked = target
      }
    }
  }

  // MARK: - Time

  /// Moves running motions to `time`. A time before the latest one given
  /// counts as the latest, so what is shown never goes back.
  mutating func advance(to time: TimeInterval) {
    guard time.isFinite else { return }
    let now = max(clock ?? time, time)
    clock = now

    for axis in Axis.allCases {
      guard let axisMotion = motion.center[axis] else { continue }
      let sample = axisMotion.sample(at: now)
      position.center[axis] = sample.value
      if sample.isFinished {
        motion.center[axis] = nil
        tracked.center[axis] = sample.value
      }
    }

    if let zoom = motion.zoom {
      let sample = zoom.logScale.sample(at: now)
      if sample.isFinished {
        motion.zoom = nil
        position.scale = zoom.rest
        tracked.scale = zoom.rest
      } else {
        position.scale = exp(sample.value)
      }
    }
  }

  // MARK: - Output

  /// The mapping to draw with, or nil while the canvas or the content has no
  /// size.
  ///
  /// - Parameter contentScaleFactor: The display scale of the canvas.
  func viewport(contentScaleFactor: CGFloat) -> CanvasViewport? {
    let scale = position.scale
    return CanvasViewport(
      contentBounds: CGRect(origin: .zero, size: contentSize),
      canvasBounds: CGRect(origin: .zero, size: canvasSize),
      contentToCanvasTransform: CGAffineTransform(
        a: scale,
        b: 0,
        c: 0,
        d: scale,
        tx: canvasSize.width / 2 - position.center.x * scale,
        ty: canvasSize.height / 2 - position.center.y * scale
      ),
      contentScaleFactor: contentScaleFactor
    )
  }

  // MARK: - Rubber band

  /// The distance shown for a pull of `distance` past a limit, over a span of
  /// `dimension`. It grows with the pull and never reaches `dimension`.
  static func rubberBand(_ distance: CGFloat, dimension: CGFloat) -> CGFloat {
    guard distance > 0, dimension > 0 else { return 0 }
    return (1 - 1 / (distance * rubberBandCoefficient / dimension + 1)) * dimension
  }

  /// The pull that `rubberBand` shows as `shown`.
  static func pull(showing shown: CGFloat, dimension: CGFloat) -> CGFloat {
    guard shown > 0, dimension > 0 else { return 0 }
    let shown = min(shown, dimension * 0.999)
    return dimension / rubberBandCoefficient * shown / (dimension - shown)
  }

  /// How much what is shown moves for each point the pull grows, where the
  /// rubber band shows `shown`: `rubberBand`'s slope. It is
  /// `rubberBandCoefficient` at the limit and falls toward zero.
  static func rubberBandSlope(showing shown: CGFloat, dimension: CGFloat) -> CGFloat {
    guard dimension > 0 else { return 0 }
    let left = 1 - min(max(shown / dimension, 0), 1)
    return rubberBandCoefficient * left * left
  }

  // MARK: - Private

  private struct Motion: Equatable, Sendable {

    /// The zoom's motion along its logarithm.
    struct Zoom: Equatable, Sendable {
      var logScale: SpringBack
      /// The zoom the motion ends at.
      var rest: CGFloat
    }

    /// The centre's motion along each axis, in content units.
    var center = PerAxis<AxisMotion?>(nil)

    /// While the zoom moves, the centre axes are springs that keep step with
    /// it, or rest at where it leads; an axis decelerates or bounces only
    /// while the zoom rests.
    var zoom: Zoom?
  }

  private static func fitScale(
    contentSize: CGSize,
    canvasSize: CGSize,
    margin: CGFloat
  ) -> CGFloat {
    let room = CGSize(width: canvasSize.width - 2 * margin, height: canvasSize.height - 2 * margin)
    guard
      contentSize.width > 0, contentSize.height > 0,
      room.width > 0, room.height > 0
    else {
      return 0
    }
    let scale = min(room.width / contentSize.width, room.height / contentSize.height)
    // A zoom too small or too large to compute positions with counts as no
    // size.
    return scale.isNormal ? scale : 0
  }

  private static func fittedPosition(
    contentSize: CGSize,
    canvasSize: CGSize,
    margin: CGFloat
  ) -> Position {
    Position(
      scale: fitScale(contentSize: contentSize, canvasSize: canvasSize, margin: margin),
      center: CGPoint(x: contentSize.width / 2, y: contentSize.height / 2)
    )
  }

  /// Follows a change of the fit, stopping any motion. A canvas that was
  /// fitted is fitted anew; otherwise the zoom and the centre are kept as
  /// far as the new limits allow.
  private mutating func followFitChange(wasFitted: Bool) {
    motion = Motion()
    forgetVelocity()
    position = wasFitted
      ? Self.fittedPosition(contentSize: contentSize, canvasSize: canvasSize, margin: fitMargin)
      : restingPosition(near: position)
    tracked = position
  }

  /// The centres along one axis that keep the canvas inside the content, or
  /// nil when the content fits the canvas along that axis and is centred.
  private static func centerRange(
    content: CGFloat,
    canvas: CGFloat,
    scale: CGFloat
  ) -> ClosedRange<CGFloat>? {
    guard scale > 0 else { return nil }
    let halfSpan = canvas / (2 * scale)
    guard content - 2 * halfSpan > 1e-9 * max(content, 1) else { return nil }
    return halfSpan...(content - halfSpan)
  }

  private func centerRange(along axis: Axis, scale: CGFloat) -> ClosedRange<CGFloat>? {
    Self.centerRange(content: contentSize[axis], canvas: canvasSize[axis], scale: scale)
  }

  private static func restingCenter(
    _ center: CGFloat,
    content: CGFloat,
    canvas: CGFloat,
    scale: CGFloat
  ) -> CGFloat {
    guard let range = centerRange(content: content, canvas: canvas, scale: scale) else {
      return content / 2
    }
    return min(max(center, range.lowerBound), range.upperBound)
  }

  /// The centre shown along one axis for a tracked centre: inside the limits
  /// it is the tracked one, past them the pull is rubber-banded.
  private static func shownCenter(
    forTracked tracked: CGFloat,
    content: CGFloat,
    canvas: CGFloat,
    scale: CGFloat
  ) -> CGFloat {
    let resting = restingCenter(tracked, content: content, canvas: canvas, scale: scale)
    let pull = (tracked - resting) * scale
    guard pull != 0 else { return resting }
    let shown = rubberBand(abs(pull), dimension: canvas)
    return resting + (pull < 0 ? -shown : shown) / scale
  }

  /// The centre a pinch shows along one axis for the centre that keeps its
  /// anchor in place.
  ///
  /// A pinch keeps the content inside the limits, so zooming out near an edge
  /// slides the content instead of showing past it. A pull that is already
  /// shown stays, without growing, so the content does not jump back inside
  /// under the fingers; the end of the gesture brings it back.
  ///
  /// - Parameter shownPull: The canvas points already shown past a limit on
  ///   this axis, signed, before the pinch.
  private static func pinchedCenter(
    _ placed: CGFloat,
    keeping shownPull: CGFloat,
    content: CGFloat,
    canvas: CGFloat,
    scale: CGFloat
  ) -> CGFloat {
    let resting = restingCenter(placed, content: content, canvas: canvas, scale: scale)
    let pull = (placed - resting) * scale
    let kept = min(max(pull, min(shownPull, 0)), max(shownPull, 0))
    return resting + kept / scale
  }

  /// The inverse of `shownCenter(forTracked:content:canvas:scale:)`.
  private static func trackedCenter(
    showing shown: CGFloat,
    content: CGFloat,
    canvas: CGFloat,
    scale: CGFloat
  ) -> CGFloat {
    let resting = restingCenter(shown, content: content, canvas: canvas, scale: scale)
    let shownPull = (shown - resting) * scale
    guard shownPull != 0 else { return resting }
    let pull = Self.pull(showing: abs(shownPull), dimension: canvas)
    return resting + (shownPull < 0 ? -pull : pull) / scale
  }

  private func shownScale(forTracked scale: CGFloat) -> CGFloat {
    let range = scaleRange
    guard range.lowerBound > 0, scale > 0 else { return range.lowerBound }
    if scale < range.lowerBound {
      return range.lowerBound
        * exp(-Self.rubberBand(log(range.lowerBound / scale), dimension: 1))
    }
    if scale > range.upperBound {
      return range.upperBound
        * exp(Self.rubberBand(log(scale / range.upperBound), dimension: 1))
    }
    return scale
  }

  private func trackedScale(showing scale: CGFloat) -> CGFloat {
    let range = scaleRange
    guard range.lowerBound > 0, scale > 0 else { return range.lowerBound }
    if scale < range.lowerBound {
      return range.lowerBound
        * exp(-Self.pull(showing: log(range.lowerBound / scale), dimension: 1))
    }
    if scale > range.upperBound {
      return range.upperBound
        * exp(Self.pull(showing: log(scale / range.upperBound), dimension: 1))
    }
    return scale
  }

  private func restingCenter(_ center: CGPoint, scale: CGFloat) -> CGPoint {
    CGPoint(
      x: Self.restingCenter(
        center.x, content: contentSize.width, canvas: canvasSize.width, scale: scale
      ),
      y: Self.restingCenter(
        center.y, content: contentSize.height, canvas: canvasSize.height, scale: scale
      )
    )
  }

  /// How far `position` shows past the limits, in canvas points, signed per
  /// axis; zero inside them.
  private func shownPull(of position: Position) -> CGSize {
    let resting = restingCenter(position.center, scale: position.scale)
    return CGSize(
      width: (position.center.x - resting.x) * position.scale,
      height: (position.center.y - resting.y) * position.scale
    )
  }

  /// The position inside the limits nearest to `position`.
  private func restingPosition(near position: Position) -> Position {
    let range = scaleRange
    let scale = min(max(position.scale, range.lowerBound), range.upperBound)
    return Position(scale: scale, center: restingCenter(position.center, scale: scale))
  }

  /// The position inside the limits that what is shown settles to. With
  /// `anchor`, the zoom moves about it: the content shown there stays in
  /// place as far as the limits allow.
  private func restingPosition(keeping anchor: CGPoint?) -> Position {
    guard let anchor else { return restingPosition(near: position) }
    let range = scaleRange
    let scale = min(max(position.scale, range.lowerBound), range.upperBound)
    return Position(
      scale: scale,
      center: restingCenter(center(keeping: anchor, atScale: scale), scale: scale)
    )
  }

  private func trackedPosition(showing shown: Position) -> Position {
    Position(
      scale: trackedScale(showing: shown.scale),
      center: CGPoint(
        x: Self.trackedCenter(
          showing: shown.center.x,
          content: contentSize.width, canvas: canvasSize.width, scale: shown.scale
        ),
        y: Self.trackedCenter(
          showing: shown.center.y,
          content: contentSize.height, canvas: canvasSize.height, scale: shown.scale
        )
      )
    )
  }

  /// The centre that keeps the content shown at `anchor` on the canvas in
  /// place when the zoom goes from the current one to `scale`. An anchor
  /// refers to what input is acting on, which is this value's own position.
  private func center(keeping anchor: CGPoint, atScale scale: CGFloat) -> CGPoint {
    let current = position.scale
    guard current > 0, scale > 0 else { return position.center }
    // A canvas point off the centre is `1 / current` content units now and
    // `1 / scale` then, so the centre moves by the difference: none at all
    // for a zoom that does not change.
    let change = 1 / current - 1 / scale
    return CGPoint(
      x: position.center.x + (anchor.x - canvasSize.width / 2) * change,
      y: position.center.y + (anchor.y - canvasSize.height / 2) * change
    )
  }

  /// Stops every running motion where it is, so new input continues from
  /// what is on screen without a jump.
  private mutating func interrupt() {
    guard isMoving else { return }
    motion = Motion()
    tracked = trackedPosition(showing: position)
  }

  /// Starts a gesture with its first movement: what the last one left (its
  /// velocity, the momentum it dropped) no longer applies.
  private mutating func openGesture() {
    guard isGestureOpen == false else { return }
    isGestureOpen = true
    didPinch = false
    zoomAnchor = nil
    forgetVelocity()
    ignoresMomentum = PerAxis(false)
  }

  private mutating func forgetVelocity() {
    velocityEstimate.reset()
    lastMovementTime = nil
    lastScrollTime = nil
  }

  /// Moves the axes the content can scroll along. Returns the translation
  /// along each of them: zero along an axis on which the content fits.
  @discardableResult
  private mutating func scroll(by translation: CGSize, stopsAtLimits: Bool) -> CGSize {
    let scale = position.scale
    guard scale > 0 else { return .zero }
    var applied = CGSize.zero
    for axis in Axis.allCases {
      let delta = translation[axis]
      guard delta.isFinite, let range = centerRange(along: axis, scale: scale) else { continue }
      // The content follows the translation, so the centre moves the other
      // way.
      var center = tracked.center[axis] - delta / scale
      if stopsAtLimits {
        center = min(max(center, range.lowerBound), range.upperBound)
      } else {
        // No farther than the pull the rubber band still tells apart, so a
        // pull without end stays a number and has a way back.
        let canvas = canvasSize[axis]
        let farthest = Self.pull(showing: canvas, dimension: canvas) / scale
        center = min(max(center, range.lowerBound - farthest), range.upperBound + farthest)
      }
      tracked.center[axis] = center
      position.center[axis] = Self.shownCenter(
        forTracked: center, content: contentSize[axis], canvas: canvasSize[axis], scale: scale
      )
      applied[axis] = delta
    }
    return applied
  }

  /// Follows the system's momentum on each axis that is free to: one that
  /// has not dropped this momentum and has no motion of its own, or only its
  /// way back from past a limit.
  private mutating func followMomentum(
    _ translation: CGSize,
    at time: TimeInterval,
    now: TimeInterval
  ) {
    // While the zoom moves, the centre belongs to that motion.
    guard motion.zoom == nil else { return }
    let scale = position.scale
    guard scale > 0 else { return }
    let previous = lastScrollTime
    var applied = CGSize.zero

    for axis in Axis.allCases {
      let delta = translation[axis]
      // An input that brings no movement along an axis says nothing about it.
      guard
        ignoresMomentum[axis] == false, delta.isFinite, delta != 0,
        let range = centerRange(along: axis, scale: scale)
      else {
        continue
      }
      // A spring on an axis that still follows momentum is its way back from
      // past a limit. Any other motion keeps its axis.
      var wayBack: SpringBack?
      switch motion.center[axis] {
      case nil:
        break
      case let .springing(spring):
        wayBack = spring
      case .decelerating:
        continue
      }

      // Where the axis is, before the rubber band.
      let from = wayBack.map { trackedCenter(showing: $0.value(at: now), along: axis, scale: scale) }
        ?? tracked.center[axis]
      var center = from - delta / scale
      if let wayBack {
        // The momentum moves the pull as more of the gesture would: on from
        // where the way back started (where the fingers, or the momentum
        // before, left the axis), not from where the way back has brought it
        // in the meantime. So what the way back moved is not counted twice.
        // It never moves the axis back out to do so, and it does not undo a
        // way back that first went farther out. Which way is out is told by
        // the limit the way back leads to: its rest is that limit exactly.
        let started = trackedCenter(showing: wayBack.start, along: axis, scale: scale)
        center = wayBack.rest == range.lowerBound
          ? max(min(started, from) - delta / scale, from)
          : min(max(started, from) - delta / scale, from)
      }

      if range.contains(from) == false {
        // An open gesture holds the axis past its limit until it ends.
        guard isGestureOpen == false else { continue }
        let limit = from < range.lowerBound ? range.lowerBound : range.upperBound
        let velocity = momentumVelocity(of: translation, along: axis, since: previous, at: time)
        let pull = limit == range.lowerBound ? limit - center : center - limit

        // It takes the axis over only when it points back inside and, fading
        // as a deceleration does, still carries the axis there.
        let pointsInside = (limit - from) * -delta > 0
        let reachesInside = pull <= 0 || velocity.map {
          decelerationDistance(from: $0) > pull + Self.decelerationEndDistance / scale
        } ?? false
        guard animates, pointsInside, reachesInside else {
          ignoresMomentum[axis] = true
          // A way back that is under way goes on. An axis the momentum was
          // holding goes back from here, at the speed it shows. So would one
          // with no way back, which no order of input leaves past its limit.
          if wayBack.map({ now < $0.startTime }) ?? true {
            let shown = position.center[axis]
            let slope = Self.rubberBandSlope(
              showing: abs(shown - limit) * scale, dimension: canvasSize[axis]
            )
            startWayBack(
              along: axis,
              to: limit,
              velocity: pointsInside ? (velocity ?? 0) * slope : 0,
              at: now,
              scale: scale
            )
          }
          continue
        }

        if pull > 0 {
          tracked.center[axis] = center
          position.center[axis] = shownCenter(forTracked: center, along: axis, scale: scale)
          applied[axis] = delta
          // Should the momentum stop here without an end, the axis goes back
          // by itself.
          startWayBack(
            along: axis, to: limit, velocity: 0, at: now + Self.stillnessInterval, scale: scale
          )
          continue
        }
      }

      // From here the axis is the momentum's alone.
      motion.center[axis] = nil
      if range.contains(center) {
        tracked.center[axis] = center
        position.center[axis] = center
        applied[axis] = delta
        continue
      }

      // The momentum runs past a limit. The axis bounces there, keeping the
      // speed it arrived with, and drops the rest of this momentum.
      let limit = center < range.lowerBound ? range.lowerBound : range.upperBound
      ignoresMomentum[axis] = true
      tracked.center[axis] = limit
      position.center[axis] = limit
      applied[axis] = (from - limit) * scale
      guard
        animates,
        let velocity = momentumVelocity(of: translation, along: axis, since: previous, at: time)
      else {
        continue
      }
      let overshoot = abs(center - limit)
      let sincePrevious = max(time - (previous ?? time), 0)
      let bounce = SpringBack(
        base: Self.bounceSpring,
        rest: limit,
        start: limit,
        velocity: velocity,
        // Back to the moment the content crossed the limit.
        startTime: now - min(TimeInterval(overshoot / abs(velocity)), sincePrevious),
        tolerance: Self.restingDistance / scale,
        reach: canvasSize[axis] / scale
      )
      motion.center[axis] = .springing(bounce)
      position.center[axis] = bounce.value(at: now)
    }

    velocityEstimate.add(applied, at: time)
    lastScrollTime = time
  }

  /// The centre's velocity along `axis`, in content units per second, of a
  /// momentum input that moved by `translation`, or nil when it has none
  /// worth acting on.
  private func momentumVelocity(
    of translation: CGSize,
    along axis: Axis,
    since previous: TimeInterval?,
    at time: TimeInterval
  ) -> CGFloat? {
    // The input's own translation over the time since the previous one says
    // how fast the content is. Inputs too close in time to tell fall back on
    // the estimate, with this input in it.
    let canvasVelocity: CGFloat?
    if let previous, time - previous >= VelocityEstimate.minimumSpan {
      canvasVelocity = translation[axis] / CGFloat(time - previous)
    } else {
      var estimate = velocityEstimate
      var translationAlongAxis = CGSize.zero
      translationAlongAxis[axis] = translation[axis]
      estimate.add(translationAlongAxis, at: time)
      canvasVelocity = estimate.velocity?[axis]
    }
    guard
      let canvasVelocity, canvasVelocity.isFinite, abs(canvasVelocity) >= 1,
      // The estimate points the other way when the fingers turned within
      // its stretch of input. Such an input has no speed to act on.
      (canvasVelocity > 0) == (translation[axis] > 0)
    else {
      return nil
    }
    return -canvasVelocity / position.scale
  }

  /// Ends a gesture, or the momentum after it: a zoom outside its limits
  /// settles, taking the centre with it; otherwise each axis that is at rest,
  /// or that the momentum was holding past its limit, goes back inside its
  /// limits or, for a host that gives a velocity, decelerates on.
  private mutating func endGesture(velocity: CGSize?, at time: TimeInterval, now: TimeInterval) {
    let fingers = fingersVelocity(given: velocity, at: time)
    let anchor = zoomAnchor
    isGestureOpen = false
    zoomAnchor = nil
    // The movement is spent: another end of this gesture brings no velocity.
    lastMovementTime = nil

    // A running zoom motion already leads inside the limits, so a second end
    // of the same gesture leaves it alone.
    guard motion.zoom == nil else { return }
    let range = scaleRange
    guard range.lowerBound > 0 else { return }
    let restingScale = min(max(position.scale, range.lowerBound), range.upperBound)
    guard abs(position.scale - restingScale) <= 1e-6 * restingScale else {
      ignoresMomentum = PerAxis(true)
      startZoomMotion(to: restingPosition(keeping: anchor), continuing: motion, at: now)
      return
    }
    position.scale = restingScale
    tracked.scale = restingScale
    let scale = restingScale

    for axis in Axis.allCases {
      // An axis in motion already leads to rest (a bounce, say), so the end
      // of the momentum that started it leaves it alone. One that the
      // momentum was still holding past its limit goes back from here.
      if let running = motion.center[axis] {
        guard
          case let .springing(wayBack) = running,
          ignoresMomentum[axis] == false, now < wayBack.startTime
        else {
          continue
        }
        motion.center[axis] = nil
      }
      let range = centerRange(along: axis, scale: scale)
      let shown = position.center[axis]
      let rest = Self.restingCenter(
        shown, content: contentSize[axis], canvas: canvasSize[axis], scale: scale
      )
      let shownPull = (shown - rest) * scale
      // Where the fingers left the axis, before the rubber band.
      let lifted = trackedCenter(showing: shown, along: axis, scale: scale)
      tracked.center[axis] = rest

      // A hundredth of a canvas point.
      guard abs(shownPull) <= 0.01 else {
        // Where the system's momentum follows, it may still take the axis on
        // from here. Fingers that were at rest leave none.
        ignoresMomentum[axis] = (velocity == nil && range != nil && fingers[axis] != 0) == false
        // For a host that gives the fingers' velocity, a flick back toward
        // the content decelerates on from where the fingers left the pull,
        // when that carries the axis back inside.
        if animates, velocity != nil, let range,
          let deceleration = AxisMotion.deceleration(
            from: lifted,
            velocity: -fingers[axis] / scale,
            at: now,
            rate: decelerationRate,
            limits: range,
            endDistance: Self.decelerationEndDistance / scale,
            bounce: Self.bounceSpring,
            tolerance: Self.restingDistance / scale,
            reach: canvasSize[axis] / scale
          )
        {
          motion.center[axis] = deceleration
          continue
        }
        // What shows past a limit moves slower than the fingers, by the
        // rubber band's slope there. The way back starts at that speed, so
        // the release does not change how fast the content moves on screen.
        // An axis the content only fits on was not moved by the fingers.
        let shownVelocity = range == nil
          ? 0
          : -fingers[axis] * Self.rubberBandSlope(showing: abs(shownPull), dimension: canvasSize[axis]) / scale
        startWayBack(along: axis, to: rest, velocity: shownVelocity, at: now, scale: scale)
        continue
      }

      position.center[axis] = rest
      // Inside the limits the content decelerates on only for a host that
      // gives the fingers' velocity; elsewhere the system's momentum follows.
      guard animates, velocity != nil, let range else { continue }
      motion.center[axis] = AxisMotion.deceleration(
        from: rest,
        velocity: -fingers[axis] / scale,
        at: now,
        rate: decelerationRate,
        limits: range,
        endDistance: Self.decelerationEndDistance / scale,
        bounce: Self.bounceSpring,
        tolerance: Self.restingDistance / scale,
        reach: canvasSize[axis] / scale
      )
    }
  }

  /// Starts the way back to `rest` for an axis that shows something else: a
  /// spring from what is shown, at `velocity`. Its start may lie ahead: the
  /// axis then stays where it is until `time`. Without animation the axis is
  /// at `rest` at once.
  private mutating func startWayBack(
    along axis: Axis,
    to rest: CGFloat,
    velocity: CGFloat,
    at time: TimeInterval,
    scale: CGFloat
  ) {
    guard animates else {
      motion.center[axis] = nil
      tracked.center[axis] = rest
      position.center[axis] = rest
      return
    }
    motion.center[axis] = .springing(
      SpringBack(
        base: Self.settleSpring,
        rest: rest,
        start: position.center[axis],
        velocity: velocity,
        startTime: time,
        tolerance: Self.restingDistance / scale,
        reach: canvasSize[axis] / scale
      )
    )
  }

  /// How far a deceleration from `velocity` travels in all, in the
  /// velocity's unit of distance. The system's momentum is taken to fade the
  /// same way.
  private func decelerationDistance(from velocity: CGFloat) -> CGFloat {
    abs(velocity) / (-1000 * log(decelerationRate))
  }

  private func shownCenter(forTracked center: CGFloat, along axis: Axis, scale: CGFloat) -> CGFloat {
    Self.shownCenter(
      forTracked: center, content: contentSize[axis], canvas: canvasSize[axis], scale: scale
    )
  }

  private func trackedCenter(showing center: CGFloat, along axis: Axis, scale: CGFloat) -> CGFloat {
    Self.trackedCenter(
      showing: center, content: contentSize[axis], canvas: canvasSize[axis], scale: scale
    )
  }

  /// The fingers' velocity at the end of a gesture, in canvas points per
  /// second: the host's, or else the one measured from the scroll inputs.
  /// Zero when the fingers had stopped before they lifted or never moved,
  /// after a pinch, and when it is not finite.
  private func fingersVelocity(given velocity: CGSize?, at time: TimeInterval) -> CGSize {
    guard
      didPinch == false,
      let lastMovementTime, time - lastMovementTime <= Self.stillnessInterval,
      let velocity = velocity ?? velocityEstimate.velocity,
      velocity.width.isFinite, velocity.height.isFinite
    else {
      return .zero
    }
    return velocity
  }

  /// Moves the zoom and the centre to `target` together on the settling
  /// spring, starting now from what is shown. Each component starts with the
  /// velocity it has in `running`, the motion this one replaces, so a new
  /// target turns the motion without a change of speed. From rest the
  /// components keep step: the centre moves in a line while the zoom moves
  /// along its logarithm.
  private mutating func startZoomMotion(
    to target: Position,
    continuing running: Motion,
    at time: TimeInterval
  ) {
    motion = Motion()
    tracked = target
    guard
      animates, position.scale > 0, target.scale > 0,
      Self.isClose(position, target) == false
    else {
      position = target
      return
    }
    motion.zoom = Motion.Zoom(
      logScale: SpringBack(
        base: Self.settleSpring,
        rest: log(target.scale),
        start: log(position.scale),
        velocity: running.zoom?.logScale.velocity(at: time) ?? 0,
        startTime: time,
        // The share of the zoom that moves nothing on the canvas by more
        // than the resting distance.
        tolerance: Self.restingDistance / max(canvasSize.width, canvasSize.height, 1)
      ),
      rest: target.scale
    )
    let scale = max(position.scale, target.scale)
    for axis in Axis.allCases {
      motion.center[axis] = .springing(
        SpringBack(
          base: Self.settleSpring,
          rest: target.center[axis],
          start: position.center[axis],
          velocity: running.center[axis]?.sample(at: time).velocity ?? 0,
          startTime: time,
          tolerance: Self.restingDistance / scale,
          reach: canvasSize[axis] / scale
        )
      )
    }
  }

  private static func isClose(_ lhs: Position, _ rhs: Position) -> Bool {
    let scale = max(rhs.scale, .leastNonzeroMagnitude)
    return abs(lhs.scale - rhs.scale) <= 1e-6 * scale
      // A hundredth of a canvas point.
      && abs(lhs.center.x - rhs.center.x) * scale <= 0.01
      && abs(lhs.center.y - rhs.center.y) * scale <= 0.01
  }
}

extension CGPoint {
  fileprivate subscript(axis: CanvasNavigation.Axis) -> CGFloat {
    get {
      switch axis {
      case .horizontal: x
      case .vertical: y
      }
    }
    set {
      switch axis {
      case .horizontal: x = newValue
      case .vertical: y = newValue
      }
    }
  }
}

extension CGSize {
  fileprivate subscript(axis: CanvasNavigation.Axis) -> CGFloat {
    get {
      switch axis {
      case .horizontal: width
      case .vertical: height
      }
    }
    set {
      switch axis {
      case .horizontal: width = newValue
      case .vertical: height = newValue
      }
    }
  }
}
