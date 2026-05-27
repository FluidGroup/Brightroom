import MetalKit
import UIKit
import os.log

/// A Metal viewport patch that follows a `UIScrollView` without taking over its delegate.
///
/// The host owns scroll semantics such as crop recording or drawing gestures. This view only
/// samples the attached scroll view on a display link, keeps the Metal drawable sized to the
/// visible viewport plus overscan, and skips rendering while the sampled viewport is unchanged.
class _ScrollViewportMetalView: UIView {

  /// Extra screen-space points rendered around the visible viewport.
  var overscanLength: CGFloat = 32 {
    didSet {
      invalidateViewport()
    }
  }

  var debugLogName = "ScrollViewportMetalView"
  var debugLog = OSLog.editingCanvas

  let canvasSize: CGSize
  let canvasView: _EditingCanvasMTKView?

  private let fallbackLabel = UILabel()
  private weak var scrollView: UIScrollView?
  private weak var viewportView: UIView?
  private weak var contentView: UIView?
  private var contentBounds: CGRect = .zero
  private var isViewportRenderingEnabled = true
  private var displayLink: CADisplayLink?
  private var lastRenderKey: RenderKey?

  #if DEBUG
  private var displayLinkTickCount = 0
  #endif

  init(canvasSize: CGSize) {
    self.canvasSize = canvasSize
    self.canvasView = MTLCreateSystemDefaultDevice().map {
      _EditingCanvasMTKView(canvasSize: canvasSize, device: $0)
    }

    super.init(frame: .zero)

    backgroundColor = .clear
    isOpaque = false
    isUserInteractionEnabled = false
    accessibilityIdentifier = "scroll-viewport-metal-view"

    if let canvasView {
      canvasView.frame = bounds
      canvasView.isUserInteractionEnabled = false
      addSubview(canvasView)
    } else {
      fallbackLabel.text = "Metal is unavailable"
      fallbackLabel.textColor = .white
      fallbackLabel.textAlignment = .center
      addSubview(fallbackLabel)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    stopDisplayLink()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()

    if window == nil {
      stopDisplayLink()
    } else {
      updateViewportIfNeeded()
    }
  }

  func attach(
    to scrollView: UIScrollView,
    viewportView: UIView,
    contentView: UIView,
    contentBounds: CGRect
  ) {
    let didChangeAttachment =
      self.scrollView !== scrollView
      || self.viewportView !== viewportView
      || self.contentView !== contentView
      || self.contentBounds != contentBounds
      || superview !== contentView

    self.scrollView = scrollView
    self.viewportView = viewportView
    self.contentView = contentView
    self.contentBounds = contentBounds

    if superview !== contentView {
      removeFromSuperview()
      contentView.addSubview(self)
    }

    if didChangeAttachment {
      invalidateViewport()
    } else {
      updateViewportIfNeeded()
    }
  }

  func detach() {
    stopDisplayLink()
    scrollView = nil
    viewportView = nil
    contentView = nil
    lastRenderKey = nil
    removeFromSuperview()
  }

  func setViewportRenderingEnabled(_ isEnabled: Bool) {
    guard isViewportRenderingEnabled != isEnabled else {
      return
    }

    isViewportRenderingEnabled = isEnabled
    lastRenderKey = nil
    isHidden = isEnabled == false

    if isEnabled {
      updateViewportIfNeeded()
    } else {
      stopDisplayLink()
    }
  }

  func invalidateViewport() {
    lastRenderKey = nil
    updateViewportIfNeeded()
  }

  @discardableResult
  func updateViewportIfNeeded() -> Bool {
    guard isViewportRenderingEnabled else {
      return false
    }

    guard let layout = makeViewportLayout() else {
      lastRenderKey = nil
      frame = .zero
      canvasView?.bounds = .zero
      fallbackLabel.bounds = .zero
      return false
    }

    let contentScaleFactor = resolvedContentScaleFactor()
    let renderKey = layout.renderKey(
      contentScaleFactor: contentScaleFactor
    )
    guard lastRenderKey != renderKey else {
      startDisplayLinkIfSamplingShouldContinue()
      return false
    }

    lastRenderKey = renderKey
    apply(layout, contentScaleFactor: contentScaleFactor)
    canvasView?.setViewport(
      visibleContentRect: layout.visibleContentRect,
      visibleCanvasFrame: layout.drawableBounds,
      zoomScale: layout.renderZoomScale
    )
    startDisplayLinkIfSamplingShouldContinue()
    return true
  }

  private func startDisplayLinkIfSamplingShouldContinue() {
    guard shouldKeepDisplayLinkAlive else {
      return
    }

    startDisplayLinkIfNeeded()
  }

  private func startDisplayLinkIfNeeded() {
    guard
      canvasView != nil,
      isViewportRenderingEnabled,
      displayLink == nil,
      window != nil
    else {
      return
    }

    let displayLink = CADisplayLink(
      target: self,
      selector: #selector(displayLinkDidTick(_:))
    )
    displayLink.preferredFramesPerSecond = window?.screen.maximumFramesPerSecond
      ?? UIScreen.main.maximumFramesPerSecond
    displayLink.add(to: .main, forMode: .common)
    self.displayLink = displayLink

    #if DEBUG
    displayLinkTickCount = 0
    #endif
  }

  private func stopDisplayLink(invalidatesRenderKey: Bool = true) {
    displayLink?.invalidate()
    displayLink = nil
    if invalidatesRenderKey {
      lastRenderKey = nil
    }
  }

  @objc private func displayLinkDidTick(_ displayLink: CADisplayLink) {
    guard window != nil else {
      stopDisplayLink()
      return
    }

    let didRequestRender = updateViewportIfNeeded()
    debugLogTick(displayLink, didRequestRender: didRequestRender)

    if didRequestRender == false, shouldKeepDisplayLinkAlive == false {
      stopDisplayLink(invalidatesRenderKey: false)
    }
  }

  private func makeViewportLayout() -> ViewportLayout? {
    guard
      let scrollView,
      let viewportView,
      let contentView,
      contentBounds.width > 0,
      contentBounds.height > 0,
      contentView.bounds.width > 0,
      contentView.bounds.height > 0
    else {
      return nil
    }

    let viewportFrameInScrollView = viewportView
      .convert(viewportView.bounds, to: scrollView)
      .standardized
    guard viewportFrameInScrollView.width > 0, viewportFrameInScrollView.height > 0 else {
      return nil
    }

    let visibleContentViewRect = scrollView
      .convert(viewportFrameInScrollView, to: contentView)
      .intersection(contentView.bounds)
      .standardized
    guard visibleContentViewRect.isNull == false, visibleContentViewRect.isEmpty == false else {
      return nil
    }

    let renderZoomScale = clampedZoomScale(scrollView.zoomScale, in: scrollView)
    guard renderZoomScale > 0 else {
      return nil
    }

    let overscanInContentView = overscanLength / renderZoomScale
    let renderedContentViewRect = visibleContentViewRect
      .insetBy(dx: -overscanInContentView, dy: -overscanInContentView)
      .intersection(contentView.bounds)
      .standardized
    guard renderedContentViewRect.isNull == false, renderedContentViewRect.isEmpty == false else {
      return nil
    }

    let visibleContentRect = mapContentViewRectToContentBounds(renderedContentViewRect)
    guard visibleContentRect.isNull == false, visibleContentRect.isEmpty == false else {
      return nil
    }

    let drawableBounds = CGRect(
      origin: .zero,
      size: CGSize(
        width: renderedContentViewRect.width * renderZoomScale,
        height: renderedContentViewRect.height * renderZoomScale
      )
    )
    guard drawableBounds.width > 0, drawableBounds.height > 0 else {
      return nil
    }

    return ViewportLayout(
      frameInContentView: renderedContentViewRect,
      visibleContentRect: visibleContentRect,
      renderZoomScale: renderZoomScale,
      drawableBounds: drawableBounds,
      canvasTransform: CGAffineTransform(
        scaleX: 1 / renderZoomScale,
        y: 1 / renderZoomScale
      )
    )
  }

  private func apply(
    _ layout: ViewportLayout,
    contentScaleFactor: CGFloat
  ) {
    isHidden = false
    frame = layout.frameInContentView
    bounds = CGRect(origin: .zero, size: layout.frameInContentView.size)

    let patchCenter = CGPoint(x: bounds.midX, y: bounds.midY)
    canvasView?.contentScaleFactor = contentScaleFactor
    canvasView?.bounds = layout.drawableBounds
    canvasView?.center = patchCenter
    canvasView?.transform = layout.canvasTransform

    fallbackLabel.bounds = layout.drawableBounds
    fallbackLabel.center = patchCenter
    fallbackLabel.transform = layout.canvasTransform
  }

  private func resolvedContentScaleFactor() -> CGFloat {
    window?.screen.scale ?? UIScreen.main.scale
  }

  private func clampedZoomScale(_ zoomScale: CGFloat, in scrollView: UIScrollView) -> CGFloat {
    let minimum = max(scrollView.minimumZoomScale, 0.0001)
    let maximum = max(scrollView.maximumZoomScale, minimum)
    return min(max(zoomScale, minimum), maximum)
  }

  private func mapContentViewRectToContentBounds(_ rect: CGRect) -> CGRect {
    guard let contentView else {
      return .null
    }

    let sourceBounds = contentView.bounds
    guard sourceBounds.width > 0, sourceBounds.height > 0 else {
      return .null
    }

    let scaleX = contentBounds.width / sourceBounds.width
    let scaleY = contentBounds.height / sourceBounds.height
    return CGRect(
      x: contentBounds.minX + (rect.minX - sourceBounds.minX) * scaleX,
      y: contentBounds.minY + (rect.minY - sourceBounds.minY) * scaleY,
      width: rect.width * scaleX,
      height: rect.height * scaleY
    )
    .intersection(contentBounds)
    .standardized
  }

  private var shouldKeepDisplayLinkAlive: Bool {
    guard let scrollView else {
      return false
    }

    if scrollView.isZooming
      || scrollView.isZoomBouncing
      || scrollView.isDragging
      || scrollView.isTracking
      || scrollView.isDecelerating
    {
      return true
    }

    if scrollView.panGestureRecognizer.state.isActiveScrollViewportGestureState {
      return true
    }

    if scrollView.pinchGestureRecognizer?.state.isActiveScrollViewportGestureState == true {
      return true
    }

    if scrollView.layer.animationKeys()?.isEmpty == false {
      return true
    }

    return false
  }

  #if DEBUG
  private func debugLogTick(
    _ displayLink: CADisplayLink,
    didRequestRender: Bool
  ) {
    displayLinkTickCount += 1
    guard didRequestRender else {
      return
    }

    debugEmit("""
      [\(debugLogName)] tick=\(displayLinkTickCount) \
      render:requested \
      timestamp:\(debugNumber(displayLink.timestamp)) \
      target:\(debugNumber(displayLink.targetTimestamp)) \
      duration:\(debugNumber(displayLink.duration))
      scroll: \(debugScrollState())
      viewport: \(debugViewportState())
      """)
  }

  private func debugEmit(_ message: String) {
    EditorLog.debug(debugLog, message)
  }

  private func debugScrollState() -> String {
    guard let scrollView else {
      return "nil"
    }

    return """
    zoomScale:\(debugNumber(scrollView.zoomScale)) \
    minZoom:\(debugNumber(scrollView.minimumZoomScale)) \
    maxZoom:\(debugNumber(scrollView.maximumZoomScale)) \
    contentSize:\(debugDescription(scrollView.contentSize)) \
    contentOffset:\(debugDescription(scrollView.contentOffset)) \
    contentInset:\(debugDescription(scrollView.contentInset)) \
    bounds:\(debugDescription(scrollView.bounds)) \
    isZooming:\(scrollView.isZooming) \
    isZoomBouncing:\(scrollView.isZoomBouncing) \
    isDragging:\(scrollView.isDragging) \
    isTracking:\(scrollView.isTracking) \
    isDecelerating:\(scrollView.isDecelerating)
    """
  }

  private func debugViewportState() -> String {
    guard let layout = makeViewportLayout() else {
      return "layout:nil"
    }

    return """
    frame:\(debugDescription(layout.frameInContentView)) \
    visible:\(debugDescription(layout.visibleContentRect)) \
    renderZoom:\(debugNumber(layout.renderZoomScale)) \
    drawable:\(debugDescription(layout.drawableBounds)) \
    bounds:\(debugDescription(bounds)) \
    metalBounds:\(canvasView.map { debugDescription($0.bounds) } ?? "nil") \
    metalTransform:\(canvasView.map { debugDescription($0.transform) } ?? "nil")
    """
  }

  private func debugDescription(_ rect: CGRect) -> String {
    "(x:\(debugNumber(rect.origin.x)), y:\(debugNumber(rect.origin.y)), w:\(debugNumber(rect.size.width)), h:\(debugNumber(rect.size.height)))"
  }

  private func debugDescription(_ size: CGSize) -> String {
    "(w:\(debugNumber(size.width)), h:\(debugNumber(size.height)))"
  }

  private func debugDescription(_ point: CGPoint) -> String {
    "(x:\(debugNumber(point.x)), y:\(debugNumber(point.y)))"
  }

  private func debugDescription(_ inset: UIEdgeInsets) -> String {
    "(top:\(debugNumber(inset.top)), left:\(debugNumber(inset.left)), bottom:\(debugNumber(inset.bottom)), right:\(debugNumber(inset.right)))"
  }

  private func debugDescription(_ transform: CGAffineTransform) -> String {
    "(a:\(debugNumber(transform.a)), b:\(debugNumber(transform.b)), c:\(debugNumber(transform.c)), d:\(debugNumber(transform.d)), tx:\(debugNumber(transform.tx)), ty:\(debugNumber(transform.ty)))"
  }

  private func debugNumber(_ value: CGFloat) -> String {
    String(format: "%.4f", Double(value))
  }

  private func debugNumber(_ value: CFTimeInterval) -> String {
    String(format: "%.4f", value)
  }
  #else
  private func debugLogTick(
    _ displayLink: CADisplayLink,
    didRequestRender: Bool
  ) {}
  #endif

  private struct ViewportLayout {
    var frameInContentView: CGRect
    var visibleContentRect: CGRect
    var renderZoomScale: CGFloat
    var drawableBounds: CGRect
    var canvasTransform: CGAffineTransform

    func renderKey(contentScaleFactor: CGFloat) -> RenderKey {
      RenderKey(
        frameInContentView: frameInContentView,
        visibleContentRect: visibleContentRect,
        renderZoomScale: renderZoomScale,
        drawableBounds: drawableBounds,
        contentScaleFactor: contentScaleFactor
      )
    }
  }

  /// Identifies the viewport sample that requires a new Metal render.
  ///
  /// The key intentionally includes only values that affect the rendered patch.
  /// Parent scroll-view rubber-band transforms are excluded so UIKit can animate
  /// already-rendered pixels during zoom bounce without forcing another draw.
  private struct RenderKey: Equatable {
    var frameInContentView: CGRect
    var visibleContentRect: CGRect
    var renderZoomScale: CGFloat
    var drawableBounds: CGRect
    var contentScaleFactor: CGFloat
  }
}

private extension UIGestureRecognizer.State {
  var isActiveScrollViewportGestureState: Bool {
    switch self {
    case .began, .changed:
      return true
    case .possible, .ended, .cancelled, .failed:
      return false
    @unknown default:
      return false
    }
  }
}
