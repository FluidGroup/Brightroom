import CoreGraphics
import Foundation
import Testing

@testable import BrightroomUI

@Suite("Canvas navigation")
struct CanvasNavigationTests {

  /// 4000 x 3000 content in an 800 x 800 canvas: the fit is 0.2, with the
  /// content 800 x 600 points and centred vertically.
  private static let content = CGSize(width: 4000, height: 3000)
  private static let canvas = CGSize(width: 800, height: 800)
  private static let canvasCenter = CGPoint(x: 400, y: 400)

  private func makeModel() -> CanvasNavigation {
    CanvasNavigation(contentSize: Self.content, canvasSize: Self.canvas)
  }

  /// Zoomed to twice the fit (0.4) about the canvas centre. The centre may
  /// then range over 1000...3000 horizontally and 1000...2000 vertically.
  private func makeZoomedModel() -> CanvasNavigation {
    var model = makeModel()
    model.handle(.zoomStep(factor: 2, anchor: Self.canvasCenter), at: 0)
    return model
  }

  /// The content point the model's viewport shows at `point` on the canvas.
  private func contentPoint(of model: CanvasNavigation, at point: CGPoint) -> CGPoint {
    guard let viewport = model.viewport(contentScaleFactor: 2) else { return .zero }
    return viewport.contentPoint(fromCanvasPoint: point)
  }

  private func isClose(_ lhs: CGFloat, _ rhs: CGFloat, tolerance: CGFloat = 1e-6) -> Bool {
    abs(lhs - rhs) <= tolerance * max(1, abs(rhs))
  }

  private func isClose(_ lhs: CGPoint, _ rhs: CGPoint, tolerance: CGFloat = 1e-6) -> Bool {
    isClose(lhs.x, rhs.x, tolerance: tolerance) && isClose(lhs.y, rhs.y, tolerance: tolerance)
  }

  // MARK: - Fit

  @Test("A new model shows the whole content, centred")
  func startsFitted() throws {
    let model = makeModel()

    #expect(model.isFitted)
    #expect(model.isMoving == false)
    #expect(isClose(model.position.scale, 0.2))
    #expect(isClose(model.position.center, CGPoint(x: 2000, y: 1500)))
    #expect(isClose(model.scaleRange.lowerBound, 0.2))
    #expect(isClose(model.scaleRange.upperBound, 1.6))

    let viewport = try #require(model.viewport(contentScaleFactor: 2))
    let transform = viewport.contentToCanvasTransform
    #expect(isClose(transform.a, 0.2))
    #expect(isClose(transform.d, 0.2))
    #expect(transform.b == 0)
    #expect(transform.c == 0)
    // The content is 800 x 600 points: flush horizontally, centred vertically.
    #expect(isClose(transform.tx, 0))
    #expect(isClose(transform.ty, 100))
    #expect(viewport.contentScaleFactor == 2)
    #expect(isClose(viewport.visibleContentRect.origin, .zero))
    #expect(isClose(viewport.visibleContentRect.width, 4000))
    #expect(isClose(viewport.visibleContentRect.height, 3000))
  }

  @Test("A canvas or content without a size has no viewport")
  func emptySizesHaveNoViewport() {
    var model = CanvasNavigation(contentSize: Self.content, canvasSize: .zero)
    #expect(model.viewport(contentScaleFactor: 2) == nil)

    model.setCanvasSize(Self.canvas)
    #expect(model.isFitted)
    #expect(isClose(model.position.scale, 0.2))
    #expect(model.viewport(contentScaleFactor: 2) != nil)

    let empty = CanvasNavigation(contentSize: .zero, canvasSize: Self.canvas)
    #expect(empty.viewport(contentScaleFactor: 2) == nil)
  }

  @Test("A size too small to compute a zoom with counts as no size")
  func unusableSizesHaveNoZoom() {
    // The fit would be 1e-313, below what divides without overflowing.
    var model = CanvasNavigation(
      contentSize: CGSize(width: 1000, height: 1000),
      canvasSize: CGSize(width: 0.5, height: 1e-310)
    )
    #expect(model.fitScale == 0)
    #expect(model.viewport(contentScaleFactor: 2) == nil)

    model.handle(.magnify(factor: 1, anchor: CGPoint(x: 0.4, y: 0)), at: 1)
    model.handle(.gestureEnded(velocity: nil), at: 1.1)
    #expect(model.position.center == CGPoint(x: 500, y: 500))
    #expect(model.isMoving == false)
  }

  @Test("Scrolling the fit moves nothing")
  func fitDoesNotScroll() {
    var model = makeModel()
    let before = model.position

    model.handle(.scroll(translation: CGSize(width: 120, height: -80), source: .gesture), at: 0)
    #expect(model.position == before)

    model.handle(.gestureEnded(velocity: nil), at: 0.1)
    #expect(model.isMoving == false)
    #expect(model.position == before)
  }

  // MARK: - Zoom

  @Test("A pinch keeps the content under the anchor in place")
  func magnifyKeepsAnchor() {
    var model = makeModel()
    let anchor = CGPoint(x: 200, y: 300)
    let content = contentPoint(of: model, at: anchor)
    #expect(isClose(content, CGPoint(x: 1000, y: 1000)))

    model.handle(.magnify(factor: 2, anchor: anchor), at: 0)

    #expect(isClose(model.position.scale, 0.4))
    #expect(isClose(contentPoint(of: model, at: anchor), content))
  }

  @Test("A pinch near an edge never shows past the content")
  func magnifyStaysInsideContent() {
    var model = makeModel()
    // The top-left corner of the content, 100 points below the canvas top.
    model.handle(.magnify(factor: 2, anchor: CGPoint(x: 0, y: 100)), at: 0)

    #expect(isClose(model.position.scale, 0.4))
    #expect(isClose(model.position.center, CGPoint(x: 1000, y: 1000)))
  }

  @Test("Zooming out near an edge slides the content instead of showing past it")
  func magnifyOutSlidesContent() {
    var model = makeModel()
    model.handle(.zoomStep(factor: 4, anchor: Self.canvasCenter), at: 0)
    model.handle(.scroll(translation: CGSize(width: -5000, height: 0), source: .wheel), at: 0)
    // At 0.8 the canvas shows 1000 units, so the centre stops at 3500.
    #expect(isClose(model.position.center, CGPoint(x: 3500, y: 1500)))

    model.handle(.magnify(factor: 0.5, anchor: Self.canvasCenter), at: 0)

    // At 0.4 it shows 2000 units: the centre slides in to 3000.
    #expect(isClose(model.position.scale, 0.4))
    #expect(isClose(model.position.center, CGPoint(x: 3000, y: 1500)))
  }

  @Test("A pinch does not jump content that is pulled past an edge back inside")
  func magnifyKeepsShownPull() {
    var model = makeZoomedModel()
    model.handle(.scroll(translation: CGSize(width: 1000, height: 0), source: .gesture), at: 0)
    let pulled = model.position
    #expect(pulled.center.x < 1000)

    // The same gesture turns into a pinch that changes nothing yet.
    model.handle(.magnify(factor: 1, anchor: Self.canvasCenter), at: 0.1)
    #expect(isClose(model.position.center, pulled.center))
    #expect(isClose(model.position.scale, pulled.scale))

    // Zooming in on the pulled edge may relieve the pull, never add to it.
    model.handle(.magnify(factor: 1.2, anchor: CGPoint(x: 700, y: 400)), at: 0.2)
    let pullBefore = (1000 - pulled.center.x) * pulled.scale
    let limit = Self.canvas.width / (2 * model.position.scale)
    let pullAfter = (limit - model.position.center.x) * model.position.scale
    #expect(pullAfter <= pullBefore + 1e-6)
    #expect(pullAfter >= 0)

    model.handle(.gestureEnded(velocity: nil), at: 1)
    model.advance(to: 3)
    #expect(model.isMoving == false)
    #expect(isClose(model.position.center.x, limit))
  }

  @Test("A pinch that stops the way back continues from where it is")
  func magnifyInterruptsSpring() {
    var model = makeZoomedModel()
    model.handle(.scroll(translation: CGSize(width: 1000, height: 0), source: .gesture), at: 0)
    model.handle(.gestureEnded(velocity: nil), at: 1)
    model.advance(to: 1.05)
    let midway = model.position
    #expect(model.isMoving)
    #expect(midway.center.x < 1000)

    model.handle(.magnify(factor: 1.001, anchor: Self.canvasCenter), at: 1.05)

    #expect(model.isMoving == false)
    #expect(isClose(model.position.center, midway.center))
  }

  @Test("A pinch below the fit is resisted, then returns to the fit")
  func magnifyBelowFitRubberBands() {
    var model = makeModel()

    model.handle(.magnify(factor: 0.5, anchor: Self.canvasCenter), at: 0)
    #expect(model.position.scale < 0.2)
    #expect(model.position.scale > 0.1)

    // A longer pinch shows less and less of itself.
    let first = model.position.scale
    model.handle(.magnify(factor: 0.5, anchor: Self.canvasCenter), at: 0)
    #expect(model.position.scale < first)
    #expect(first - model.position.scale < 0.2 - first)

    model.handle(.gestureEnded(velocity: nil), at: 1)
    #expect(model.isMoving)

    model.advance(to: 1.05)
    #expect(model.isMoving)
    #expect(model.position.scale < 0.2)

    model.advance(to: 2)
    #expect(model.isMoving == false)
    #expect(model.isFitted)
    #expect(isClose(model.position.center, CGPoint(x: 2000, y: 1500)))
  }

  @Test("A pinch above the largest zoom is resisted, then returns to it")
  func magnifyAboveMaximumRubberBands() {
    var model = makeModel()
    model.handle(.zoomStep(factor: 100, anchor: Self.canvasCenter), at: 0)
    #expect(isClose(model.position.scale, 1.6))

    model.handle(.magnify(factor: 2, anchor: Self.canvasCenter), at: 0)
    #expect(model.position.scale > 1.6)
    #expect(model.position.scale < 3.2)

    model.handle(.gestureEnded(velocity: nil), at: 1)
    model.advance(to: 2)
    #expect(model.isMoving == false)
    #expect(isClose(model.position.scale, 1.6))
  }

  @Test("A stepped zoom keeps the content under its anchor in place")
  func zoomStepKeepsAnchor() {
    var model = makeModel()
    let anchor = CGPoint(x: 200, y: 300)
    let content = contentPoint(of: model, at: anchor)
    #expect(isClose(content, CGPoint(x: 1000, y: 1000)))

    model.handle(.zoomStep(factor: 2, anchor: anchor), at: 0)

    #expect(isClose(model.position.scale, 0.4))
    #expect(isClose(contentPoint(of: model, at: anchor), content))
    #expect(isClose(model.position.center, CGPoint(x: 1500, y: 1250)))
  }

  @Test("A stepped zoom stops at the limits")
  func zoomStepStopsAtLimits() {
    var model = makeModel()

    model.handle(.zoomStep(factor: 0.5, anchor: Self.canvasCenter), at: 0)
    #expect(model.isFitted)
    #expect(model.isMoving == false)

    model.handle(.zoomStep(factor: 100, anchor: Self.canvasCenter), at: 0)
    #expect(isClose(model.position.scale, 1.6))
    #expect(model.isMoving == false)
  }

  @Test("Toggling the zoom goes to a closer look at the anchor, and back to the fit")
  func toggleZoom() {
    var model = makeModel()
    model.animates = false
    let anchor = CGPoint(x: 200, y: 300)
    let content = contentPoint(of: model, at: anchor)

    model.handle(.toggleZoom(anchor: anchor), at: 0)
    #expect(isClose(model.position.scale, 0.6))
    #expect(isClose(contentPoint(of: model, at: anchor), content))

    model.handle(.toggleZoom(anchor: anchor), at: 1)
    #expect(model.isFitted)
    #expect(isClose(model.position.center, CGPoint(x: 2000, y: 1500)))
  }

  @Test("Toggling the zoom moves over time when animated")
  func toggleZoomAnimates() {
    var model = makeModel()

    model.handle(.toggleZoom(anchor: Self.canvasCenter), at: 0)
    #expect(model.isMoving)
    #expect(model.isFitted)

    model.advance(to: 0.05)
    #expect(model.position.scale > 0.2)
    #expect(model.position.scale < 0.6)

    model.advance(to: 1)
    #expect(model.isMoving == false)
    #expect(isClose(model.position.scale, 0.6))
  }

  // MARK: - Zoom to a scale

  @Test("Zooming to a scale clamps it to the limits")
  func zoomToScaleClamps() {
    var model = makeModel()

    model.handle(.zoom(scale: 100, anchor: nil, animated: false), at: 0)
    #expect(isClose(model.position.scale, 1.6))

    model.handle(.zoom(scale: 0.01, anchor: nil, animated: false), at: 1)
    #expect(model.isFitted)
    #expect(isClose(model.position.center, CGPoint(x: 2000, y: 1500)))
  }

  @Test("Zooming to a scale keeps the content under the anchor in place")
  func zoomToScaleKeepsAnchor() {
    var model = makeModel()
    let anchor = CGPoint(x: 200, y: 300)
    let content = contentPoint(of: model, at: anchor)

    model.handle(.zoom(scale: 0.4, anchor: anchor, animated: false), at: 0)

    #expect(isClose(model.position.scale, 0.4))
    #expect(isClose(contentPoint(of: model, at: anchor), content))
    #expect(isClose(model.position.center, CGPoint(x: 1500, y: 1250)))
  }

  @Test("Zooming to a scale without an anchor keeps the centre")
  func zoomToScaleKeepsCentre() {
    var model = makeZoomedModel()
    model.handle(.scroll(translation: CGSize(width: -200, height: 40), source: .wheel), at: 0)
    let centre = model.position.center
    #expect(isClose(centre, CGPoint(x: 2500, y: 1400)))

    model.handle(.zoom(scale: 0.8, anchor: nil, animated: false), at: 1)

    #expect(isClose(model.position.scale, 0.8))
    #expect(isClose(model.position.center, centre))
  }

  @Test("Zooming to a scale without animation arrives at once")
  func zoomToScaleAtOnce() {
    var model = makeModel()

    model.handle(.zoom(scale: 0.8, anchor: nil, animated: false), at: 0)

    #expect(model.isMoving == false)
    #expect(isClose(model.position.scale, 0.8))
    #expect(isClose(model.targetScale, 0.8))
  }

  @Test("An animated zoom to a scale settles there, and steps taken meanwhile compound")
  func zoomToScaleAnimates() {
    var model = makeModel()
    #expect(isClose(model.targetScale, 0.2))

    model.handle(.zoom(scale: 0.4, anchor: nil, animated: true), at: 0)
    #expect(model.isMoving)
    #expect(model.isFitted)
    #expect(isClose(model.targetScale, 0.4))

    model.advance(to: 0.05)
    #expect(model.position.scale > 0.2)
    #expect(model.position.scale < 0.4)
    #expect(isClose(model.targetScale, 0.4))

    // A second step on the way doubles where the first was heading.
    model.handle(.zoom(scale: model.targetScale * 2, anchor: nil, animated: true), at: 0.05)
    #expect(isClose(model.targetScale, 0.8))

    model.advance(to: 2)
    #expect(model.isMoving == false)
    #expect(isClose(model.position.scale, 0.8))
    #expect(isClose(model.targetScale, 0.8))
    #expect(isClose(model.position.center, CGPoint(x: 2000, y: 1500)))
  }

  @Test("Without animation an animated zoom to a scale completes at once")
  func zoomToScaleWithoutAnimation() {
    var model = makeModel()
    model.animates = false

    model.handle(.zoom(scale: 0.8, anchor: nil, animated: true), at: 0)

    #expect(model.isMoving == false)
    #expect(isClose(model.position.scale, 0.8))
  }

  @Test("Zooming to a scale takes over a zoom toggle from where it is")
  func zoomToScaleInterruptsToggle() {
    var model = makeModel()
    model.handle(.toggleZoom(anchor: Self.canvasCenter), at: 0)
    model.advance(to: 0.05)
    let midway = model.position
    #expect(model.isMoving)
    #expect(isClose(model.targetScale, 0.6))

    // Animated, the zoom goes on from what is shown, without a jump.
    model.handle(.zoom(scale: 1.2, anchor: nil, animated: true), at: 0.05)
    #expect(model.position == midway)
    #expect(isClose(model.targetScale, 1.2))
    model.advance(to: 2)
    #expect(model.isMoving == false)
    #expect(isClose(model.position.scale, 1.2))

    // Not animated, it is there at once.
    model.handle(.toggleZoom(anchor: Self.canvasCenter), at: 3)
    model.advance(to: 3.05)
    #expect(model.isMoving)
    model.handle(.zoom(scale: 0.4, anchor: nil, animated: false), at: 3.05)
    #expect(model.isMoving == false)
    #expect(isClose(model.position.scale, 0.4))
  }

  /// How fast the zoom's logarithm and the centre change over the tenth of
  /// a millisecond after `time`, measured on a copy of `model`, which has
  /// been moved to `time`.
  private func velocity(
    of model: CanvasNavigation,
    at time: TimeInterval
  ) -> (logScale: CGFloat, center: CGPoint) {
    let interval = 1e-4
    var later = model
    later.advance(to: time + interval)
    return (
      logScale: (log(later.position.scale) - log(model.position.scale)) / interval,
      center: CGPoint(
        x: (later.position.center.x - model.position.center.x) / interval,
        y: (later.position.center.y - model.position.center.y) / interval
      )
    )
  }

  @Test("A zoom to a new scale on the way keeps the speed of the zoom it takes over")
  func zoomRetargetKeepsZoomVelocity() {
    var model = makeModel()
    model.handle(.zoom(scale: 0.4, anchor: nil, animated: true), at: 0)
    // A tenth of a second in, the zoom is near its fastest: ln 2 b² t e^(-bt)
    // with b = 2π / 0.4 is 3.56 a second.
    var before = model
    before.advance(to: 0.1 - 1e-4)
    let speed = velocity(of: before, at: 0.1 - 1e-4).logScale
    #expect(speed > 3.4)

    // A second step on the way, as a held Command-plus repeats it.
    model.advance(to: 0.1)
    let retargeted = model.position
    model.handle(.zoom(scale: model.targetScale * 2, anchor: nil, animated: true), at: 0.1)
    #expect(model.position == retargeted)
    #expect(abs(velocity(of: model, at: 0.1).logScale - speed) < 0.05 * speed)

    model.advance(to: 2)
    #expect(model.isMoving == false)
    #expect(isClose(model.position.scale, 0.8))
    #expect(isClose(model.position.center, CGPoint(x: 2000, y: 1500)))
  }

  @Test("A zoom on the way keeps the speed at which the centre moves")
  func zoomRetargetKeepsCenterVelocity() {
    var model = makeZoomedModel()
    model.handle(.scroll(translation: CGSize(width: -5000, height: -5000), source: .wheel), at: 0)
    #expect(isClose(model.position.center, CGPoint(x: 3000, y: 2000)))

    // Zooming to the fit takes the centre from the corner to the middle.
    model.handle(.zoom(scale: 0.2, anchor: nil, animated: true), at: 1)
    var before = model
    before.advance(to: 1.05 - 1e-4)
    let speed = velocity(of: before, at: 1.05 - 1e-4).center
    #expect(speed.x < -1000)
    #expect(speed.y < -500)

    // Zooming in on the way keeps the centre that is shown, which goes on
    // at the speed it had and comes back to rest there.
    model.advance(to: 1.05)
    let retargeted = model.position
    model.handle(.zoom(scale: 0.4, anchor: nil, animated: true), at: 1.05)
    #expect(model.position == retargeted)
    let after = velocity(of: model, at: 1.05).center
    #expect(abs(after.x - speed.x) < 0.05 * abs(speed.x))
    #expect(abs(after.y - speed.y) < 0.05 * abs(speed.y))

    model.advance(to: 3)
    #expect(model.isMoving == false)
    #expect(isClose(model.position.scale, 0.4))
    #expect(isClose(model.position.center, retargeted.center))
  }

  @Test("A zoom to a scale that is not finite and positive, or without limits, is ignored")
  func zoomToInvalidScaleIsIgnored() {
    var model = makeZoomedModel()
    let before = model.position

    for scale in [CGFloat.nan, .infinity, 0, -1] {
      model.handle(.zoom(scale: scale, anchor: nil, animated: false), at: 1)
      #expect(model.position == before)
    }
    model.handle(.zoom(scale: 0.8, anchor: CGPoint(x: CGFloat.nan, y: 0), animated: true), at: 1)
    #expect(model.position == before)
    #expect(model.isMoving == false)

    // A canvas without a size has no limits to zoom within.
    var empty = CanvasNavigation(contentSize: Self.content, canvasSize: .zero)
    empty.handle(.zoom(scale: 1, anchor: nil, animated: false), at: 0)
    #expect(empty.position.scale == 0)
  }

  // MARK: - Scroll

  @Test("A gesture moves the content with the fingers")
  func gestureScrollFollowsFingers() {
    var model = makeZoomedModel()

    // The content moves 100 points right and 40 down, so the centre moves
    // the other way by that many points over the zoom.
    model.handle(.scroll(translation: CGSize(width: 100, height: 40), source: .gesture), at: 0)

    #expect(isClose(model.position.center, CGPoint(x: 1750, y: 1400)))
    #expect(isClose(model.position.scale, 0.4))
  }

  @Test("A gesture pull past the edge is resisted, then springs back")
  func gestureScrollRubberBands() {
    var model = makeZoomedModel()

    // 1000 points right asks for a centre of -500: 600 points past the edge.
    model.handle(.scroll(translation: CGSize(width: 1000, height: 0), source: .gesture), at: 0)
    let pulled = model.position.center.x
    #expect(pulled < 1000)
    #expect(pulled > -500)
    // What shows is the rubber band of the 600 points:
    // (1 - 1 / (0.55 pull / 800 + 1)) 800.
    let shown: CGFloat = (1 - 1 / (600 * 0.55 / 800 + 1)) * 800
    #expect(isClose(pulled, 1000 - shown / 0.4))
    #expect(isClose(model.position.center.y, 1500))

    model.handle(.gestureEnded(velocity: nil), at: 1)
    #expect(model.isMoving)

    model.advance(to: 1.05)
    #expect(model.position.center.x > pulled)
    #expect(model.position.center.x < 1000)

    model.advance(to: 2)
    #expect(model.isMoving == false)
    #expect(isClose(model.position.center, CGPoint(x: 1000, y: 1500)))
  }

  @Test("Momentum after a release past an edge with the fingers at rest moves only the other axis")
  func momentumAfterRestingReleaseFollowsOtherAxis() {
    var model = makeZoomedModel()
    model.handle(.scroll(translation: CGSize(width: 1000, height: 0), source: .gesture), at: 0)
    // A second after the fingers last moved.
    model.handle(.gestureEnded(velocity: nil), at: 1)

    // The way back runs on while the momentum arrives, and momentum that
    // points back inside does not take it over: the fingers were at rest.
    var springing = model
    springing.advance(to: 1.01)

    // 200 points up move the centre 500 units down, to its limit.
    model.handle(.scroll(translation: CGSize(width: -300, height: 200), source: .momentum), at: 1.01)
    #expect(model.position.center.x == springing.position.center.x)
    #expect(isClose(model.position.center.y, 1000))
    #expect(model.isMoving)

    // Once back inside, the axis still leaves the rest of that momentum alone.
    model.advance(to: 2)
    #expect(model.isMoving == false)
    model.handle(.scroll(translation: CGSize(width: -300, height: 0), source: .momentum), at: 2.01)
    #expect(isClose(model.position.center, CGPoint(x: 1000, y: 1000)))

    // The next gesture scrolls again, and so does its momentum.
    model.handle(.scroll(translation: CGSize(width: -40, height: 0), source: .gesture), at: 3)
    model.handle(.gestureEnded(velocity: nil), at: 3.05)
    model.handle(.scroll(translation: CGSize(width: -40, height: 0), source: .momentum), at: 3.1)
    #expect(isClose(model.position.center, CGPoint(x: 1200, y: 1000)))
  }

  @Test("Momentum that reaches the edge bounces there with its speed, and the rest of it is dropped")
  func momentumBouncesAtLimits() {
    var model = makeZoomedModel()
    model.handle(.scroll(translation: CGSize(width: 10, height: 0), source: .gesture), at: 0)
    model.handle(.gestureEnded(velocity: nil), at: 0.05)
    #expect(model.isMoving == false)
    #expect(isClose(model.position.center, CGPoint(x: 1975, y: 1500)))

    // Inside the limits momentum moves the content like the fingers did.
    model.handle(.scroll(translation: CGSize(width: 90, height: 0), source: .momentum), at: 0.1)
    #expect(isClose(model.position.center, CGPoint(x: 1750, y: 1500)))
    #expect(model.isMoving == false)

    // 320 points in a tenth of a second is 3200 points per second. They ask
    // for a centre of 950: 20 points past the edge at 1000, so the content
    // crossed the edge 20 / 3200 seconds before this input.
    model.handle(.scroll(translation: CGSize(width: 320, height: 0), source: .momentum), at: 0.2)
    #expect(model.isMoving)
    // A critically damped spring that leaves its rest at speed `v` is
    // `v t e^(-bt)` away after `t` seconds; the bounce spring's `b` is 10.
    let speed = 320 / (0.2 - 0.1)
    func bounce(_ elapsed: Double) -> CGFloat {
      CGFloat(speed * elapsed * exp(-10 * elapsed))
    }
    let crossing = 0.2 - 20 / speed
    #expect(isClose(model.position.center.x, 1000 - bounce(0.2 - crossing) / 0.4))
    #expect(isClose(model.position.center.y, 1500))

    // The rest of that momentum is dropped.
    var bouncing = model
    bouncing.advance(to: 0.21)
    model.handle(.scroll(translation: CGSize(width: 500, height: 0), source: .momentum), at: 0.21)
    #expect(model.position == bouncing.position)

    // The end of that momentum does not restart the way back.
    bouncing.advance(to: 0.25)
    model.handle(.gestureEnded(velocity: nil), at: 0.25)
    #expect(model.position == bouncing.position)
    #expect(model.isMoving)

    // The bounce is deepest a tenth of a second after the crossing, by
    // `v / (b e)`: 3200 / (10 e) = 117.7 points.
    model.advance(to: crossing + 0.1)
    #expect(isClose(model.position.center.x, 1000 - CGFloat(speed / (10 * M_E)) / 0.4))

    model.advance(to: 3)
    #expect(model.isMoving == false)
    #expect(model.position.center == CGPoint(x: 1000, y: 1500))
  }

  @Test("A wheel stops at the edge")
  func wheelStopsAtLimits() {
    var model = makeZoomedModel()

    model.handle(.scroll(translation: CGSize(width: 0, height: -5000), source: .wheel), at: 0)

    #expect(isClose(model.position.center, CGPoint(x: 2000, y: 2000)))
    #expect(model.isMoving == false)
  }

  @Test("Fingers resting on the device stop a motion where it is")
  func touchDownStopsMotion() {
    var model = makeZoomedModel()
    model.handle(.scroll(translation: CGSize(width: 1000, height: 0), source: .gesture), at: 0)
    model.handle(.gestureEnded(velocity: nil), at: 1)
    model.advance(to: 1.05)
    let midway = model.position
    #expect(model.isMoving)

    model.handle(.touchDown, at: 1.05)
    #expect(model.isMoving == false)
    #expect(isClose(model.position.center, midway.center))

    // Lifting without moving lets it finish the way back.
    model.handle(.gestureEnded(velocity: nil), at: 1.5)
    #expect(model.isMoving)
    model.advance(to: 3)
    #expect(isClose(model.position.center, CGPoint(x: 1000, y: 1500)))
  }

  @Test("Scrolling is possible only when the content exceeds the canvas")
  func canScroll() {
    #expect(makeModel().canScroll == false)
    #expect(makeZoomedModel().canScroll)
  }

  @Test("New input continues from where a motion is, without a jump")
  func inputInterruptsSpring() {
    var model = makeZoomedModel()
    model.handle(.scroll(translation: CGSize(width: 1000, height: 0), source: .gesture), at: 0)
    model.handle(.gestureEnded(velocity: nil), at: 1)
    model.advance(to: 1.05)
    #expect(model.isMoving)
    let midway = model.position

    model.handle(.scroll(translation: .zero, source: .gesture), at: 1.05)
    #expect(model.isMoving == false)
    #expect(isClose(model.position.center, midway.center))
    #expect(isClose(model.position.scale, midway.scale))

    // The pull that is still shown continues to resist.
    model.handle(.scroll(translation: CGSize(width: 50, height: 0), source: .gesture), at: 1.06)
    #expect(model.position.center.x < midway.center.x)
    #expect(midway.center.x - model.position.center.x < 50 / 0.4)
  }

  // MARK: - Layout

  @Test("A resized canvas stays fitted")
  func resizeKeepsFit() {
    var model = makeModel()

    model.setCanvasSize(CGSize(width: 1000, height: 500))

    #expect(model.isFitted)
    #expect(isClose(model.position.scale, 500.0 / 3000.0))
    #expect(isClose(model.position.center, CGPoint(x: 2000, y: 1500)))
  }

  @Test("A resized canvas keeps a zoomed position as far as the limits allow")
  func resizeKeepsZoomedPosition() {
    var model = makeZoomedModel()
    model.handle(.scroll(translation: CGSize(width: -200, height: 0), source: .gesture), at: 0)
    model.handle(.gestureEnded(velocity: nil), at: 0.05)
    #expect(isClose(model.position.center, CGPoint(x: 2500, y: 1500)))

    model.setCanvasSize(CGSize(width: 600, height: 600))
    #expect(isClose(model.position.scale, 0.4))
    #expect(isClose(model.position.center, CGPoint(x: 2500, y: 1500)))

    // A canvas so large that 0.4 is below its fit moves to the new fit.
    model.setCanvasSize(CGSize(width: 2400, height: 2400))
    #expect(model.isFitted)
    #expect(isClose(model.position.scale, 0.6))
    #expect(isClose(model.position.center, CGPoint(x: 2000, y: 1500)))
  }

  @Test("A fit margin leaves room around the fitted content; zoomed in, the content reaches the edges")
  func fitMarginInsetsTheFit() throws {
    var model = makeModel()
    model.setFitMargin(12)

    // The content fits the 776 points inside the margins at 0.194: 776 x 582
    // points, 12 from the sides and 109 from the top and the bottom.
    #expect(model.isFitted)
    #expect(isClose(model.fitScale, 0.194))
    #expect(isClose(model.scaleRange.upperBound, 0.194 * 8))
    #expect(model.canScroll == false)
    let fitted = try #require(model.viewport(contentScaleFactor: 2)).contentToCanvasTransform
    #expect(isClose(fitted.a, 0.194))
    #expect(isClose(fitted.tx, 12))
    #expect(isClose(fitted.ty, 109))

    // Zoomed in, the limits are the canvas's edges: the content's corner
    // reaches the canvas's corner.
    model.handle(.zoomStep(factor: 4, anchor: Self.canvasCenter), at: 0)
    model.handle(.scroll(translation: CGSize(width: 5000, height: 5000), source: .wheel), at: 0)
    let zoomed = try #require(model.viewport(contentScaleFactor: 2)).contentToCanvasTransform
    #expect(isClose(zoomed.tx, 0))
    #expect(isClose(zoomed.ty, 0))

    // A resize and a change of the margin keep a fit fitted.
    model.handle(.zoomStep(factor: 0.01, anchor: Self.canvasCenter), at: 1)
    #expect(model.isFitted)
    model.setCanvasSize(CGSize(width: 1000, height: 500))
    #expect(model.isFitted)
    #expect(isClose(model.position.scale, 476.0 / 3000.0))
    model.setFitMargin(0)
    #expect(model.isFitted)
    #expect(isClose(model.position.scale, 500.0 / 3000.0))

    // A canvas with no room inside its margins has no fit.
    model.setFitMargin(250)
    #expect(model.fitScale == 0)
    #expect(model.viewport(contentScaleFactor: 2) == nil)
  }

  @Test("New content starts fitted")
  func newContentResets() {
    var model = makeZoomedModel()

    model.setContentSize(CGSize(width: 1000, height: 2000))

    #expect(model.isFitted)
    #expect(isClose(model.position.scale, 0.4))
    #expect(isClose(model.position.center, CGPoint(x: 500, y: 1000)))
  }

  @Test("Without animation a motion completes at once")
  func motionsCompleteWithoutAnimation() {
    var model = makeZoomedModel()
    model.animates = false

    model.handle(.scroll(translation: CGSize(width: 1000, height: 0), source: .gesture), at: 0)
    model.handle(.gestureEnded(velocity: nil), at: 1)

    #expect(model.isMoving == false)
    #expect(isClose(model.position.center, CGPoint(x: 1000, y: 1500)))
  }

  // MARK: - Output

  @Test("The viewport shows the position's centre at the canvas centre")
  func viewportShowsPosition() throws {
    var model = makeZoomedModel()
    model.handle(.scroll(translation: CGSize(width: -130, height: 70), source: .gesture), at: 0)
    #expect(isClose(model.position.center, CGPoint(x: 2325, y: 1325)))

    let viewport = try #require(model.viewport(contentScaleFactor: 2))
    #expect(isClose(viewport.contentPoint(fromCanvasPoint: Self.canvasCenter), model.position.center))
    // 800 points at a zoom of 0.4 show 2000 content units either way.
    #expect(isClose(viewport.contentPoint(fromCanvasPoint: .zero), CGPoint(x: 1325, y: 325)))
    #expect(isClose(viewport.visibleContentRect.width, 2000))
    #expect(isClose(viewport.visibleContentRect.height, 2000))
  }

  @Test("The rubber band grows with the pull, stays under its span, and inverts")
  func rubberBand() {
    var previous: CGFloat = 0
    for pull in stride(from: CGFloat(10), through: 100_000, by: 997) {
      let shown = CanvasNavigation.rubberBand(pull, dimension: 800)
      #expect(shown > previous)
      #expect(shown < 800)
      #expect(shown < pull)
      previous = shown
    }

    for pull in [CGFloat(1), 50, 600, 4000] {
      let shown = CanvasNavigation.rubberBand(pull, dimension: 800)
      #expect(isClose(CanvasNavigation.pull(showing: shown, dimension: 800), pull))
    }

    #expect(CanvasNavigation.rubberBand(0, dimension: 800) == 0)
    #expect(CanvasNavigation.rubberBand(100, dimension: 0) == 0)
  }
}
