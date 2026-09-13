import BrightroomEngine
import MetalKit
import UIKit

/// Hosts an editing canvas's drawable and brush input for a surface-owned frame loop.
///
/// The host applies a viewport and calls `drawIfNeeded()` each visible frame. This
/// view never schedules its own display link or setNeedsDisplay-driven render.
final class _EditingCanvasMTKView: MTKView, MTKViewDelegate {

  /// Brush gesture state, including the active live stamps waiting for display.
  private struct StrokeState: ~Copyable {
    var configuredBrush: EditingCanvasBrush?
    var activeBrush: EditingCanvasBrush?
    var smoothing = EditingCanvasStrokeSmoothingConfiguration()
    var smoother = EditingCanvasStrokeSmoother()
    var lastStampPoint: CGPoint?
    var activeStamps: [CGPoint] = []
    var generation = 0
  }

  private let renderer: EditingCanvasRenderer
  private var strokeState = StrokeState()
  /// Input changes stay pending until a drawable has actually been presented.
  /// Sampling an unchanged viewport must not acquire a drawable or submit GPU work.
  private var needsCanvasDisplay = true
  private var lastDrawnSize: CGSize?

  /// Delivers a completed content-space stroke to the host. Completion signals
  /// that its rendering inputs have been refreshed; stale completions are ignored.
  var onStrokeCommit: ((EditingCanvasStrokeRecord, @escaping () -> Void) -> Void)?

  var hasRenderImages: Bool { renderer.hasRenderImages }

  init(canvasSize: CGSize, device: MTLDevice) {
    self.renderer = EditingCanvasRenderer(canvasSize: canvasSize, device: device)

    super.init(frame: .zero, device: device)

    backgroundColor = .clear
    isOpaque = false
    layer.isOpaque = false
    framebufferOnly = false
    colorPixelFormat = EditingCanvasImageProcessing.drawablePixelFormat
    clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    enableSetNeedsDisplay = false
    isPaused = true
    preferredFramesPerSecond = Self.targetFrameRate(for: nil)
    autoResizeDrawable = true
    // Commit the sampled viewport with the surrounding Core Animation frame,
    // including overlays whose presentation geometry supplied that sample.
    presentsWithTransaction = true
    isMultipleTouchEnabled = true
    delegate = self
    accessibilityIdentifier = "editing-canvas-metal-view"
    isAccessibilityElement = true
    accessibilityLabel = "Brush mask renderer"
    isHidden = true
    if let metalLayer = layer as? CAMetalLayer {
      metalLayer.maximumDrawableCount = 3
    }
    applyColorSpaceContract()

    reset()
  }

  /// Pins the drawable's color contract so the Display-P3 pixels Core Image
  /// encodes into the drawable are interpreted as Display-P3 by the compositor —
  /// one conversion, no double color management. MTKView (re)creates its
  /// CAMetalLayer/drawable from `colorPixelFormat`, so the layer colorspace is
  /// (re)asserted here and again from `didMoveToWindow`. This is SDR Display-P3
  /// (no EDR); it matches the export's Display-P3 tag.
  private func applyColorSpaceContract() {
    guard let metalLayer = layer as? CAMetalLayer else { return }
    metalLayer.colorspace = EditingCanvasImageProcessing.drawableColorSpace
  }

  @available(*, unavailable)
  required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()

    guard window != nil else {
      // The recognizer belongs to the surface and may still be tracking when
      // this canvas is replaced. Do not carry its stroke into another lifetime.
      cancelActiveStroke()
      return
    }

    applyColorSpaceContract()
    preferredFramesPerSecond = Self.targetFrameRate(for: window?.screen)
    needsCanvasDisplay = true
  }

  private static func targetFrameRate(for screen: UIScreen?) -> Int {
    let maximum = screen?.maximumFramesPerSecond ?? UIScreen.main.maximumFramesPerSecond
    return min(max(maximum, 60), 120)
  }

  func configure(
    brush: EditingCanvasBrush,
    smoothing: EditingCanvasStrokeSmoothingConfiguration
  ) {
    strokeState.configuredBrush = brush

    if strokeState.smoothing != smoothing {
      strokeState.smoothing = smoothing
      strokeState.smoother.configure(smoothing)
      cancelActiveStroke()
      strokeState.lastStampPoint = nil
    }
  }

  func setRenderImages(_ images: EditingCanvasRenderImages) {
    renderer.setRenderImages(images)
    needsCanvasDisplay = true
  }

  func setCommittedStrokes(_ records: [EditingCanvasStrokeRecord]) {
    if renderer.setCommittedStrokes(records) {
      needsCanvasDisplay = true
    }
  }

  func setViewport(_ viewport: EditingCanvasRenderer.Viewport) {
    if renderer.setViewport(viewport) {
      needsCanvasDisplay = true
    }
  }

  func reset() {
    cancelActiveStroke()
  }

  /// Refreshes the drawable after a host lifecycle transition, even when the
  /// retained image and viewport inputs have not changed.
  func setNeedsCanvasDisplay() {
    needsCanvasDisplay = true
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    if strokeState.activeStamps.isEmpty == false {
      cancelActiveStroke()
    }
    renderer.drawableSizeDidChange()
    needsCanvasDisplay = true
  }

  /// Draws changed input once, keeping the previous drawable while it is unchanged.
  /// Returns true only when this call presents a frame. Unavailable drawables
  /// leave the change pending so the host's next tick can retry it.
  @discardableResult
  func drawIfNeeded() -> Bool {
    guard needsCanvasDisplay || lastDrawnSize != bounds.size else { return false }
    needsCanvasDisplay = true
    draw()
    return needsCanvasDisplay == false
  }

  func draw(in view: MTKView) {
    guard let drawable = currentDrawable,
          let descriptor = currentRenderPassDescriptor else { return }

    let activeStroke = strokeState.activeBrush.map { brush in
      EditingCanvasRenderer.ActiveStroke(brush: brush, stamps: strokeState.activeStamps)
    }
    guard renderer.render(.init(
      texture: drawable.texture,
      renderPassDescriptor: descriptor,
      viewportSize: bounds.size,
      activeStroke: activeStroke,
      preferredFramesPerSecond: preferredFramesPerSecond
    )) != nil else { return }

    // The renderer has committed and waited until scheduling. Present directly
    // in the current Core Animation transaction, matching presentsWithTransaction.
    drawable.present()
    lastDrawnSize = bounds.size
    needsCanvasDisplay = false
  }

  func beginStroke(at rawPoint: CGPoint) {
    guard let brush = strokeState.configuredBrush else {
      return
    }

    strokeState.generation += 1
    isHidden = false
    strokeState.activeStamps.removeAll(keepingCapacity: true)
    strokeState.activeBrush = brush
    strokeState.smoother.begin(at: rawPoint)
    strokeState.lastStampPoint = rawPoint
    appendLiveStamps([rawPoint])
  }

  func appendStroke(points rawPoints: [CGPoint]) {
    guard let brush = strokeState.activeBrush, rawPoints.isEmpty == false else {
      return
    }

    let sampleDistance = max(CGFloat(brush.size * brush.spacing) * 0.5, 2)
    let smoothedPoints = strokeState.smoother.append(
      rawPoints,
      sampleDistance: sampleDistance
    )
    let stamps = smoothedPoints.flatMap { point -> [CGPoint] in
      stampPoints(to: point, brush: brush)
    }

    appendLiveStamps(stamps)
  }

  func endStroke(at rawPoint: CGPoint) {
    guard let brush = strokeState.activeBrush else {
      return
    }

    let sampleDistance = max(CGFloat(brush.size * brush.spacing) * 0.5, 2)
    let smoothedPoints = strokeState.smoother.finish(
      at: rawPoint,
      sampleDistance: sampleDistance
    )
    let stamps = smoothedPoints.flatMap { point -> [CGPoint] in
      stampPoints(to: point, brush: brush)
    }

    appendLiveStamps(stamps)
    commitActiveStroke()
    strokeState.smoother.reset()
    strokeState.lastStampPoint = nil
  }

  func cancelStroke() {
    cancelActiveStroke()
  }

  private func cancelActiveStroke() {
    strokeState.generation += 1
    strokeState.smoother.reset()
    strokeState.activeStamps.removeAll(keepingCapacity: true)
    strokeState.activeBrush = nil
    isHidden = false
    strokeState.lastStampPoint = nil
    needsCanvasDisplay = true
  }

  private func stampPoints(to point: CGPoint, brush: EditingCanvasBrush) -> [CGPoint] {
    guard let lastStampPoint = strokeState.lastStampPoint else {
      strokeState.lastStampPoint = point
      return [point]
    }

    let distance = hypot(point.x - lastStampPoint.x, point.y - lastStampPoint.y)
    let spacing = max(CGFloat(brush.size * brush.spacing), 1)

    guard distance >= spacing else {
      return []
    }

    let count = Int(distance / spacing)
    guard count > 0 else {
      return []
    }

    var stamps: [CGPoint] = []
    var newestStampPoint = lastStampPoint

    for index in 1...count {
      let progress = CGFloat(index) * spacing / distance
      let stamp = CGPoint(
        x: lastStampPoint.x + (point.x - lastStampPoint.x) * progress,
        y: lastStampPoint.y + (point.y - lastStampPoint.y) * progress
      )
      stamps.append(stamp)
      newestStampPoint = stamp
    }

    strokeState.lastStampPoint = newestStampPoint
    return stamps
  }

  private func appendLiveStamps(_ stamps: [CGPoint]) {
    guard strokeState.activeBrush != nil, stamps.isEmpty == false else {
      return
    }

    strokeState.activeStamps += stamps
    isHidden = false
    needsCanvasDisplay = true
  }

  private func commitActiveStroke() {
    guard let brush = strokeState.activeBrush, strokeState.activeStamps.isEmpty == false else {
      return
    }

    let stamps = strokeState.activeStamps
    strokeState.activeStamps.removeAll(keepingCapacity: true)
    strokeState.activeBrush = nil
    needsCanvasDisplay = true
    let generation = strokeState.generation

    let record = EditingCanvasStrokeRecord(stamps: stamps, brush: brush)
    let finishStrokeRendering = { [weak self] in
      guard let self else { return }
      self.finishCommittedStrokeRendering(for: generation)
    }

    if let onStrokeCommit {
      onStrokeCommit(record, finishStrokeRendering)
    } else {
      finishStrokeRendering()
    }
  }

  private func finishCommittedStrokeRendering(for generation: Int) {
    if Thread.isMainThread == false {
      DispatchQueue.main.async { [weak self] in
        self?.finishCommittedStrokeRendering(for: generation)
      }
      return
    }

    guard strokeState.generation == generation, strokeState.activeStamps.isEmpty else {
      return
    }

    isHidden = false
  }
}
