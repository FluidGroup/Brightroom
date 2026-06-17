import CoreImage
import BrightroomEngine
import BrightroomParametric
import MetalKit
import simd
import UIKit

/// Uniform values for drawing one soft circular brush stamp into a mask texture.
struct EditingCanvasBrushStampUniforms {
  var canvasSize: SIMD2<Float>
  var center: SIMD2<Float>
  var radius: Float
  var hardness: Float
  var opacity: Float
  var _padding: Float = 0
}

private struct EditingCanvasViewportSourceTextureKey: Equatable {
  var sourceExtent: CGRect
  var visibleContentRect: CGRect
  var visibleCanvasFrame: CGRect
  var pixelWidth: Int
  var pixelHeight: Int
}

private struct EditingCanvasViewportSourceTexture {
  let key: EditingCanvasViewportSourceTextureKey
  let texture: MTLTexture
  let image: CIImage
}

private struct EditingCanvasViewportRenderTextures {
  let pixelWidth: Int
  let pixelHeight: Int
  let maskTexture: MTLTexture
}

private struct EditingCanvasViewportPreparedLayersCacheKey: Equatable {
  var visibleContentRect: CGRect
  var visibleCanvasFrame: CGRect
  var pixelWidth: Int
  var pixelHeight: Int
}

/// Viewport-resolution bakes of `renderImages.base` / `renderImages.adjusted`
/// for the prepared-base composite path. The render images themselves are not
/// part of the key; `setRenderImages` invalidates this cache, so within one
/// render-images generation the bakes only depend on the viewport and the
/// drawable size. This keeps live stroke frames from re-running the full
/// base/adjusted Core Image chains.
private struct EditingCanvasViewportPreparedLayersCache {
  let key: EditingCanvasViewportPreparedLayersCacheKey
  let baseTexture: MTLTexture
  let adjustedTexture: MTLTexture
  let baseImage: CIImage
  let adjustedImage: CIImage
}

/// Texture-backed bake of `renderImages.adjusted` (the local-effect layer), keyed
/// only on the render-images generation (NOT the viewport). `setRenderImages`
/// invalidates it, so during a gesture (rotation / pan / zoom — which change only
/// the viewport) the expensive blur graph is evaluated once and every frame
/// resamples this texture instead of re-running it.
///
/// Only `adjusted` is baked: `base` is the global effects applied to the
/// (now GPU-resident) source, which are pointwise and cheap to re-evaluate per
/// frame — baking it too would just double the held texture memory for no
/// meaningful frame-time win.
private struct EditingCanvasPreparedContentLayers {
  let adjustedTexture: MTLTexture
  let adjustedImage: CIImage
}


private enum EditingCanvasViewportRenderPath: String {
  case clear
  case baseImage = "base-image"
  case cachedSourceBase = "cached-source-base"
  case coreImageComposite = "core-image-composite"
}

struct EditingCanvasRenderImages {
  let source: CIImage
  let effects: EffectPipeline
  let base: CIImage
  let adjusted: CIImage
  let localEffect: EffectPipeline
  let usesPreparedBaseImage: Bool

  var hasLocalEffect: Bool {
    localEffect.hasEnabledEffects
  }
}

final class _EditingCanvasMTKView: MTKView, MTKViewDelegate {

  /// Canvas-content viewport values used to render the current drawable.
  ///
  /// A viewport may be supplied at draw time so the renderer can resolve
  /// presentation-layer geometry as close as possible to the Metal draw pass.
  struct Viewport {
    var visibleContentRect: CGRect
    var visibleCanvasFrame: CGRect
    var zoomScale: CGFloat
  }

  typealias ViewportProvider = () -> Viewport?

  private typealias BrushStampUniforms = EditingCanvasBrushStampUniforms
  // @MainActor: reads UIScreen frame-rate properties, which are main-actor only.
  @MainActor
  private enum LiveFrameRate {
    static let minimum = 60
    static let maximum = 120

    static func targetMaximum(for screen: UIScreen?) -> Int {
      let screenMaximum = screen?.maximumFramesPerSecond ?? UIScreen.main.maximumFramesPerSecond
      return min(max(screenMaximum, minimum), maximum)
    }

    static func range(for screen: UIScreen?) -> CAFrameRateRange {
      let maximumFramesPerSecond = Float(targetMaximum(for: screen))
      return CAFrameRateRange(
        minimum: Float(minimum),
        maximum: maximumFramesPerSecond,
        preferred: maximumFramesPerSecond
      )
    }
  }

  /// Rendering inputs and caches that are scoped to the current visible canvas viewport.
  private struct ViewportState: ~Copyable {
    var renderImages: EditingCanvasRenderImages?
    var sourceTexture: EditingCanvasViewportSourceTexture?
    var preparedContentLayers: EditingCanvasPreparedContentLayers?
    var preparedLayersCache: EditingCanvasViewportPreparedLayersCache?
    var renderTextures: EditingCanvasViewportRenderTextures?
    var usesCachedSourceRendering = false
    var visibleContentRect: CGRect
    var visibleCanvasFrame: CGRect = .zero

    init(canvasSize: CGSize) {
      self.visibleContentRect = CGRect(origin: .zero, size: canvasSize)
    }
  }

  /// Brush gesture state, including the active live stamps waiting for display.
  private struct StrokeState: ~Copyable {
    var committedRecords: [EditingCanvasStrokeRecord] = []
    var configuredBrush: EditingCanvasBrush?
    var activeBrush: EditingCanvasBrush?
    var smoothing = EditingCanvasStrokeSmoothingConfiguration()
    var smoother = EditingCanvasStrokeSmoother()
    var lastStampPoint: CGPoint?
    var activeStamps: [CGPoint] = []
    var pendingLiveStamps: [CGPoint] = []
    var generation = 0
  }

  /// CADisplayLink state for live stroke refreshes and throttled metrics updates.
  private struct LiveRefreshState: ~Copyable {
    var displayLink: CADisplayLink?
    var lastMetricsPublishTime: CFTimeInterval = 0
    let metricsPublishInterval: CFTimeInterval = 1.0 / 12.0
  }

  /// Rolling draw-rate sample used by the demo diagnostics overlay.
  private struct DrawMetrics: ~Copyable {
    var sampleStartTime: CFTimeInterval = CACurrentMediaTime()
    var sampleCount = 0
    var framesPerSecond: Double = 0
    let idleResetInterval: CFTimeInterval = 1.0
  }

  #if DEBUG
  /// Debug-only counters for spotting expensive canvas-rendering path drift.
  ///
  /// The summary log is intentionally coarse-grained: it reports path counts,
  /// cache misses, and slow-frame counts once per interval without changing the
  /// render behavior that is being measured.
  private struct PerformanceDiagnostics {
    enum CacheMiss: String {
      case sourceTexture = "source-texture"
      case renderTextures = "render-textures"
      case preparedContentLayers = "prepared-content-layers"
      case preparedLayers = "prepared-layers"
    }

    enum Invalidation: String {
      case renderImages = "render-images"
      case cachedSourceMode = "cached-source-mode"
      case committedStrokes = "committed-strokes"
      case viewport = "viewport"
      case drawableSize = "drawable-size"
    }

    var lastLogTime = CACurrentMediaTime()
    var frameCount = 0
    var slowFrameCount = 0
    var clearFrameCount = 0
    var baseImageFrameCount = 0
    var cachedSourceBaseFrameCount = 0
    var coreImageCompositeFrameCount = 0
    var sourceTextureMissCount = 0
    var renderTexturesMissCount = 0
    var preparedContentLayersMissCount = 0
    var preparedLayersMissCount = 0
    var invalidationCount = 0
    var lastInvalidation: Invalidation?

    let logInterval: CFTimeInterval = 1.0

    mutating func recordInvalidation(_ reason: Invalidation) {
      invalidationCount += 1
      lastInvalidation = reason
    }

    mutating func recordCacheMiss(_ cache: CacheMiss) {
      switch cache {
      case .sourceTexture:
        sourceTextureMissCount += 1
      case .renderTextures:
        renderTexturesMissCount += 1
      case .preparedContentLayers:
        preparedContentLayersMissCount += 1
      case .preparedLayers:
        preparedLayersMissCount += 1
      }
    }

    mutating func recordRender(
      path: EditingCanvasViewportRenderPath,
      duration: CFTimeInterval,
      frameBudget: CFTimeInterval,
      usesCachedSourceRendering: Bool,
      usesPreparedBaseImage: Bool,
      hasLocalEffect: Bool,
      hasRenderableStroke: Bool,
      drawableSize: CGSize?,
      visibleContentRect: CGRect,
      visibleCanvasFrame: CGRect
    ) {
      frameCount += 1
      if duration > frameBudget {
        slowFrameCount += 1
      }

      switch path {
      case .clear:
        clearFrameCount += 1
      case .baseImage:
        baseImageFrameCount += 1
      case .cachedSourceBase:
        cachedSourceBaseFrameCount += 1
      case .coreImageComposite:
        coreImageCompositeFrameCount += 1
      }

      let now = CACurrentMediaTime()
      guard now - lastLogTime >= logInterval else {
        return
      }

      EditorLog.debug(.editingCanvasPerformance, """
        [EditingCanvasRender]
        frames:\(frameCount) slow:\(slowFrameCount) budgetMs:\(formatMilliseconds(frameBudget))
        path clear:\(clearFrameCount) base:\(baseImageFrameCount) cachedBase:\(cachedSourceBaseFrameCount) coreComposite:\(coreImageCompositeFrameCount)
        cacheMiss source:\(sourceTextureMissCount) textures:\(renderTexturesMissCount) contentLayers:\(preparedContentLayersMissCount) preparedLayers:\(preparedLayersMissCount)
        invalidations:\(invalidationCount) lastInvalidation:\(lastInvalidation?.rawValue ?? "none")
        last path:\(path.rawValue) ms:\(formatMilliseconds(duration)) cachedSourceEnabled:\(usesCachedSourceRendering) preparedBase:\(usesPreparedBaseImage) localEffect:\(hasLocalEffect) stroke:\(hasRenderableStroke) drawable:\(format(drawableSize))
        content:\(format(visibleContentRect)) canvasFrame:\(format(visibleCanvasFrame))
        """)

      resetInterval(now: now)
    }

    private mutating func resetInterval(now: CFTimeInterval) {
      lastLogTime = now
      frameCount = 0
      slowFrameCount = 0
      clearFrameCount = 0
      baseImageFrameCount = 0
      cachedSourceBaseFrameCount = 0
      coreImageCompositeFrameCount = 0
      sourceTextureMissCount = 0
      renderTexturesMissCount = 0
      preparedContentLayersMissCount = 0
      preparedLayersMissCount = 0
      invalidationCount = 0
      lastInvalidation = nil
    }

    private func formatMilliseconds(_ duration: CFTimeInterval) -> String {
      String(format: "%.2f", duration * 1000)
    }

    private func format(_ size: CGSize?) -> String {
      guard let size else {
        return "nil"
      }

      return "\(formatNumber(size.width))x\(formatNumber(size.height))"
    }

    private func format(_ rect: CGRect) -> String {
      "(\(formatNumber(rect.minX)),\(formatNumber(rect.minY)),\(formatNumber(rect.width)),\(formatNumber(rect.height)))"
    }

    private func formatNumber(_ value: CGFloat) -> String {
      String(format: "%.1f", Double(value))
    }
  }
  #endif

  private let canvasSize: CGSize
  private let commandQueue: MTLCommandQueue
  private let brushMaskPipeline: MTLRenderPipelineState
  private var viewportState: ViewportState
  private var strokeState = StrokeState()
  private var liveRefreshState = LiveRefreshState()
  private var drawMetrics = DrawMetrics()
  #if DEBUG
  private var performanceDiagnostics = PerformanceDiagnostics()
  #endif
  private var viewportProvider: ViewportProvider?
  var activeStampCount: Int {
    strokeState.activeStamps.count
  }
  var committedStampCount: Int {
    strokeState.committedRecords.reduce(0) { $0 + $1.stamps.count }
  }
  var strokeCount: Int {
    strokeState.committedRecords.count
  }
  var framesPerSecond: Double {
    drawMetrics.framesPerSecond
  }
  var onMetricsChange: (() -> Void)?
  var onStrokeCommit: ((EditingCanvasStrokeRecord, @escaping () -> Void) -> Void)?

  var hasRenderImages: Bool { viewportState.renderImages != nil }

  private lazy var ciContext: CIContext = {
    [unowned self] in
    CIContext(
      mtlCommandQueue: self.commandQueue,
      options: [
        .name: "EditingCanvas",
        // Wide-gamut, high-precision working space so Display-P3 / out-of-sRGB
        // chroma survives filtering instead of being clamped (see the color
        // contract in EditingCanvasImageProcessing).
        .workingColorSpace: EditingCanvasImageProcessing.workingColorSpace,
        .workingFormat: EditingCanvasImageProcessing.workingFormat,
      ]
    )
  }()

  init(canvasSize: CGSize, device: MTLDevice) {
    self.canvasSize = canvasSize
    self.commandQueue = device.makeCommandQueue()!
    self.viewportState = ViewportState(canvasSize: canvasSize)

    do {
      let library = try Self.makeBrushMaskShaderLibrary(device: device)
      self.brushMaskPipeline = try Self.makeBrushMaskPipeline(device: device, library: library)
    } catch {
      fatalError("Failed to create Editing Canvas pipeline: \(error)")
    }

    super.init(frame: .zero, device: device)

    backgroundColor = .clear
    isOpaque = false
    layer.isOpaque = false
    framebufferOnly = false
    colorPixelFormat = EditingCanvasImageProcessing.drawablePixelFormat
    clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    enableSetNeedsDisplay = true
    isPaused = true
    preferredFramesPerSecond = LiveFrameRate.targetMaximum(for: nil)
    autoResizeDrawable = true
    // The canvas frame and the host scroll view's transform change in the
    // same Core Animation transaction (rotation streaming, zoom). Presenting
    // outside that transaction lets the compositor stretch the previous
    // texture into the new bounds for a frame, which reads as warping.
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

  isolated deinit {
    stopLiveDisplayLink()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    // Re-assert: MTKView can rebuild its drawable/layer when entering a window,
    // which would drop the colorspace and silently reinterpret the drawable.
    applyColorSpaceContract()
    updatePreferredFrameRate()
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

    if isHidden == false {
      setNeedsDisplay()
    }
  }

  func setRenderImages(_ images: EditingCanvasRenderImages) {
    viewportState.renderImages = images
    // New render images may carry new source content with an identical
    // extent; the source-texture key is content-blind, so it must be
    // dropped here like every other viewport cache.
    viewportState.sourceTexture = nil
    viewportState.renderTextures = nil
    invalidateViewportCoreImageLayerCaches()
    invalidatePreparedContentLayers()
    #if DEBUG
    performanceDiagnostics.recordInvalidation(.renderImages)
    #endif
    setNeedsDisplay()
  }

  func setViewportCachedSourceEnabled(_ isEnabled: Bool) {
    guard viewportState.usesCachedSourceRendering != isEnabled else {
      return
    }

    viewportState.usesCachedSourceRendering = isEnabled
    viewportState.sourceTexture = nil
    viewportState.renderTextures = nil
    invalidateViewportCoreImageLayerCaches()
    invalidatePreparedContentLayers()
    #if DEBUG
    performanceDiagnostics.recordInvalidation(.cachedSourceMode)
    #endif
    setNeedsDisplay()
  }

  func setCommittedStrokes(_ records: [EditingCanvasStrokeRecord]) {
    // Hosts re-send committed strokes on every state update; identical records
    // would needlessly schedule a frame.
    guard strokeState.committedRecords != records else {
      return
    }

    // Committed strokes are rasterized live every frame (no cache), so updating
    // the records and scheduling a redraw is all that is needed.
    strokeState.committedRecords = records
    #if DEBUG
    performanceDiagnostics.recordInvalidation(.committedStrokes)
    #endif
    setNeedsDisplay()
  }

  func setViewportProvider(
    _ provider: ViewportProvider?,
    schedulesDisplay: Bool = true
  ) {
    viewportProvider = provider
    if schedulesDisplay {
      setNeedsDisplay()
    }
  }

  func setViewport(
    visibleContentRect rect: CGRect,
    visibleCanvasFrame frame: CGRect,
    zoomScale: CGFloat
  ) {
    updateViewport(
      .init(
        visibleContentRect: rect,
        visibleCanvasFrame: frame,
        zoomScale: zoomScale
      ),
      schedulesDisplay: true
    )
  }

  func setViewport(_ viewport: Viewport) {
    updateViewport(viewport, schedulesDisplay: true)
  }

  private func updateViewport(
    _ viewport: Viewport,
    schedulesDisplay: Bool
  ) {
    let canvasRect = CGRect(origin: .zero, size: canvasSize)
    let nextRect = viewport.visibleContentRect.intersection(canvasRect)
    let nextFrame = viewport.visibleCanvasFrame

    guard nextRect.isNull == false, nextRect.isEmpty == false else {
      return
    }

    let didChangeViewport = viewportState.visibleContentRect.equalTo(nextRect) == false
      || viewportState.visibleCanvasFrame.equalTo(nextFrame) == false
    guard didChangeViewport else {
      return
    }

    viewportState.visibleContentRect = nextRect
    viewportState.visibleCanvasFrame = nextFrame
    viewportState.sourceTexture = nil
    viewportState.renderTextures = nil
    invalidateViewportCoreImageLayerCaches()
    #if DEBUG
    performanceDiagnostics.recordInvalidation(.viewport)
    #endif
    if schedulesDisplay {
      setNeedsDisplay()
      onMetricsChange?()
    }
  }

  func reset() {
    cancelActiveStroke()
    onMetricsChange?()
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    if strokeState.activeStamps.isEmpty == false {
      cancelActiveStroke()
    }
    viewportState.renderTextures = nil
    invalidateViewportCoreImageLayerCaches()
    #if DEBUG
    performanceDiagnostics.recordInvalidation(.drawableSize)
    #endif
    setNeedsDisplay()
  }

  func draw(in view: MTKView) {
    defer {
      recordDrawSample()
    }

    updateViewportFromProvider()
    renderViewportImage()
  }

  private func updateViewportFromProvider() {
    guard let viewport = viewportProvider?() else {
      return
    }

    updateViewport(viewport, schedulesDisplay: false)
  }

  func beginStroke(at rawPoint: CGPoint) {
    guard let brush = strokeState.configuredBrush else {
      return
    }

    strokeState.generation += 1
    isHidden = false
    strokeState.activeStamps.removeAll(keepingCapacity: true)
    strokeState.pendingLiveStamps.removeAll(keepingCapacity: true)
    strokeState.activeBrush = brush
    strokeState.smoother.begin(at: rawPoint)
    strokeState.lastStampPoint = rawPoint
    renderLiveStamps([rawPoint], flushImmediately: true)
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

    renderLiveStamps(stamps)
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

    renderLiveStamps(stamps, flushImmediately: true)
    commitActiveStroke()
    strokeState.smoother.reset()
    strokeState.lastStampPoint = nil
  }

  func cancelStroke() {
    cancelActiveStroke()
  }

  private func recordDrawSample(now: CFTimeInterval = CACurrentMediaTime()) {
    if drawMetrics.sampleCount == 0, now - drawMetrics.sampleStartTime > drawMetrics.idleResetInterval {
      drawMetrics.sampleStartTime = now
    }

    drawMetrics.sampleCount += 1
    let elapsed = now - drawMetrics.sampleStartTime
    guard elapsed >= 0.5 else {
      return
    }

    drawMetrics.framesPerSecond = Double(drawMetrics.sampleCount) / elapsed
    drawMetrics.sampleCount = 0
    drawMetrics.sampleStartTime = now
    onMetricsChange?()
  }

  private func encodeClearTexture(_ texture: MTLTexture?, commandBuffer: MTLCommandBuffer) {
    guard let texture else {
      return
    }

    let descriptor = MTLRenderPassDescriptor()
    descriptor.colorAttachments[0].texture = texture
    descriptor.colorAttachments[0].loadAction = .clear
    descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    descriptor.colorAttachments[0].storeAction = .store

    commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)?.endEncoding()
  }

  private func cancelActiveStroke() {
    strokeState.generation += 1
    strokeState.smoother.reset()
    strokeState.activeStamps.removeAll(keepingCapacity: true)
    strokeState.pendingLiveStamps.removeAll(keepingCapacity: true)
    strokeState.activeBrush = nil
    stopLiveDisplayLink()
    isHidden = false
    setNeedsDisplay()
    strokeState.lastStampPoint = nil
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

  private func renderLiveStamps(_ stamps: [CGPoint], flushImmediately: Bool = false) {
    guard strokeState.activeBrush != nil, stamps.isEmpty == false else {
      return
    }

    strokeState.activeStamps += stamps
    strokeState.pendingLiveStamps += stamps
    isHidden = false
    startLiveDisplayLinkIfNeeded()
    if flushImmediately {
      strokeState.pendingLiveStamps.removeAll(keepingCapacity: true)
      setNeedsDisplay()
      publishLiveMetricsIfNeeded(force: true)
    } else {
      publishLiveMetricsIfNeeded()
    }
  }

  private func commitActiveStroke() {
    guard let brush = strokeState.activeBrush, strokeState.activeStamps.isEmpty == false else {
      setNeedsDisplay()
      return
    }

    stopLiveDisplayLink()

    let stamps = strokeState.activeStamps
    strokeState.activeStamps.removeAll(keepingCapacity: true)
    strokeState.activeBrush = nil
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
    onMetricsChange?()
    setNeedsDisplay()
  }

  private func startLiveDisplayLinkIfNeeded() {
    guard liveRefreshState.displayLink == nil else { return }

    let displayLink = CADisplayLink(
      target: self,
      selector: #selector(liveDisplayLinkDidTick(_:))
    )
    displayLink.preferredFrameRateRange = LiveFrameRate.range(for: window?.screen)
    displayLink.add(to: .main, forMode: .common)
    liveRefreshState.displayLink = displayLink
  }

  private func updatePreferredFrameRate() {
    preferredFramesPerSecond = LiveFrameRate.targetMaximum(for: window?.screen)
    liveRefreshState.displayLink?.preferredFrameRateRange = LiveFrameRate.range(for: window?.screen)
  }

  private func stopLiveDisplayLink() {
    liveRefreshState.displayLink?.invalidate()
    liveRefreshState.displayLink = nil
  }

  @objc private func liveDisplayLinkDidTick(_ displayLink: CADisplayLink) {
    if strokeState.pendingLiveStamps.isEmpty == false {
      strokeState.pendingLiveStamps.removeAll(keepingCapacity: true)
      setNeedsDisplay()
    }
    publishLiveMetricsIfNeeded(now: displayLink.timestamp)
  }

  private func publishLiveMetricsIfNeeded(
    force: Bool = false,
    now: CFTimeInterval = CACurrentMediaTime()
  ) {
    guard force || now - liveRefreshState.lastMetricsPublishTime >= liveRefreshState.metricsPublishInterval else {
      return
    }

    liveRefreshState.lastMetricsPublishTime = now
    onMetricsChange?()
  }

  private func renderViewportImage() {
    #if DEBUG
    let renderStartTime = CACurrentMediaTime()
    let diagnosticsRenderImages = viewportState.renderImages
    #endif

    guard
      let renderImages = viewportState.renderImages,
      let drawable = currentDrawable,
      let descriptor = currentRenderPassDescriptor,
      let commandBuffer = commandQueue.makeCommandBuffer(),
      bounds.width > 0,
      bounds.height > 0,
      viewportState.visibleContentRect.width > 0,
      viewportState.visibleContentRect.height > 0,
      viewportState.visibleCanvasFrame.width > 0,
      viewportState.visibleCanvasFrame.height > 0
    else {
      clearCurrentDrawable()
      #if DEBUG
      recordPerformanceRender(
        path: .clear,
        startedAt: renderStartTime,
        renderImages: diagnosticsRenderImages,
        drawable: nil,
        hasRenderableStroke: false
      )
      #endif
      return
    }

    let hasRenderableStroke = hasRenderableStroke(in: viewportState.visibleContentRect)

    if viewportState.usesCachedSourceRendering, renderImages.usesPreparedBaseImage == false {
      let path = renderViewportCachedSource(
        renderImages,
        drawable: drawable,
        descriptor: descriptor,
        commandBuffer: commandBuffer
      )
      #if DEBUG
      recordPerformanceRender(
        path: path,
        startedAt: renderStartTime,
        renderImages: renderImages,
        drawable: drawable,
        hasRenderableStroke: hasRenderableStroke
      )
      #endif
      return
    }

    guard renderImages.hasLocalEffect,
          hasRenderableStroke
    else {
      // No local effect here: `base` is the global effects applied to the
      // GPU-resident source (pointwise → cheap), so re-evaluating it per frame
      // needs no bake.
      renderViewportBaseImage(
        renderImages.base,
        drawable: drawable,
        descriptor: descriptor,
        commandBuffer: commandBuffer
      )
      #if DEBUG
      recordPerformanceRender(
        path: .baseImage,
        startedAt: renderStartTime,
        renderImages: renderImages,
        drawable: drawable,
        hasRenderableStroke: hasRenderableStroke
      )
      #endif
      return
    }

    renderViewportCoreImageComposite(
      renderImages,
      drawable: drawable,
      descriptor: descriptor,
      commandBuffer: commandBuffer
    )
    #if DEBUG
    recordPerformanceRender(
      path: .coreImageComposite,
      startedAt: renderStartTime,
      renderImages: renderImages,
      drawable: drawable,
      hasRenderableStroke: hasRenderableStroke
    )
    #endif
  }

  #if DEBUG
  private func recordPerformanceRender(
    path: EditingCanvasViewportRenderPath,
    startedAt startTime: CFTimeInterval,
    renderImages: EditingCanvasRenderImages?,
    drawable: CAMetalDrawable?,
    hasRenderableStroke: Bool
  ) {
    let frameBudget = 1.0 / Double(max(preferredFramesPerSecond, LiveFrameRate.minimum))
    let drawableSize = drawable.map {
      CGSize(width: CGFloat($0.texture.width), height: CGFloat($0.texture.height))
    }

    performanceDiagnostics.recordRender(
      path: path,
      duration: CACurrentMediaTime() - startTime,
      frameBudget: frameBudget,
      usesCachedSourceRendering: viewportState.usesCachedSourceRendering,
      usesPreparedBaseImage: renderImages?.usesPreparedBaseImage ?? false,
      hasLocalEffect: renderImages?.hasLocalEffect ?? false,
      hasRenderableStroke: hasRenderableStroke,
      drawableSize: drawableSize,
      visibleContentRect: viewportState.visibleContentRect,
      visibleCanvasFrame: viewportState.visibleCanvasFrame
    )
  }
  #endif

  private func renderViewportBaseImage(
    _ image: CIImage,
    drawable: CAMetalDrawable,
    descriptor: MTLRenderPassDescriptor,
    commandBuffer: MTLCommandBuffer
  ) {
    descriptor.colorAttachments[0].loadAction = .clear
    descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    descriptor.colorAttachments[0].storeAction = .store
    commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)?.endEncoding()

    let renderBounds = CGRect(
      x: 0,
      y: 0,
      width: drawable.texture.width,
      height: drawable.texture.height
    )
    guard let destinationFrame = viewportTextureContentFrame(
      pixelWidth: drawable.texture.width,
      pixelHeight: drawable.texture.height
    ) else {
      clearCurrentDrawable()
      return
    }
    let scaleX = destinationFrame.width / viewportState.visibleContentRect.width
    let scaleY = destinationFrame.height / viewportState.visibleContentRect.height
    let visibleImage = image
      .transformed(
        by: CGAffineTransform(
          translationX: -viewportState.visibleContentRect.minX,
          y: -viewportState.visibleContentRect.minY
        )
      )
      .transformed(
        by: CGAffineTransform(
          scaleX: scaleX,
          y: scaleY
        )
      )
      .transformed(
        by: CGAffineTransform(
          translationX: destinationFrame.minX,
          y: destinationFrame.minY
        )
      )
      .transformed(by: CGAffineTransform(scaleX: 1, y: -1))
      .transformed(by: CGAffineTransform(translationX: 0, y: renderBounds.height))
      .cropped(to: renderBounds)

    ciContext.render(
      visibleImage,
      to: drawable.texture,
      commandBuffer: commandBuffer,
      bounds: renderBounds,
      colorSpace: EditingCanvasImageProcessing.drawableColorSpace
    )
    commandBuffer.commit()
    commandBuffer.waitUntilScheduled()
    drawable.present()
  }

  /// The full source extent expressed in drawable pixels at the current zoom.
  ///
  /// Diagonal-based radii (Gaussian blur, sharpen) use this as their reference
  /// so a "value 40" blur is always `diagonal(source) / 50` of the source,
  /// independent of viewport zoom. The scale mirrors the brush-stamp pixel
  /// scale (content points → drawable pixels): a zoomed-in viewport magnifies
  /// fewer content points into the same drawable, so the source measured in
  /// drawable pixels grows, and the radius grows with it — exactly cancelling
  /// the magnification so the on-screen blur matches the exported result.
  private func viewportRadiusReferenceExtent(
    sourceExtent: CGRect,
    pixelWidth: Int,
    pixelHeight: Int
  ) -> CGRect? {
    let visibleContentRect = viewportState.visibleContentRect
    let visibleCanvasFrame = viewportState.visibleCanvasFrame
    guard
      bounds.width > 0, bounds.height > 0,
      visibleContentRect.width > 0, visibleContentRect.height > 0,
      visibleCanvasFrame.width > 0, visibleCanvasFrame.height > 0,
      sourceExtent.width > 0, sourceExtent.height > 0
    else {
      return nil
    }

    let drawableScaleX = CGFloat(pixelWidth) / bounds.width
    let drawableScaleY = CGFloat(pixelHeight) / bounds.height
    let pixelScaleX = visibleCanvasFrame.width * drawableScaleX / visibleContentRect.width
    let pixelScaleY = visibleCanvasFrame.height * drawableScaleY / visibleContentRect.height
    let scale = max((pixelScaleX + pixelScaleY) * 0.5, 0.0001)

    return CGRect(
      origin: .zero,
      size: CGSize(
        width: sourceExtent.width * scale,
        height: sourceExtent.height * scale
      )
    )
  }

  @discardableResult
  /// The cached-source path now only serves the no-local-effect base preview
  /// (mode `.viewportBase`): every local adjustment bakes its effect and uses
  /// the prepared path. So this just renders the effects-applied base.
  private func renderViewportCachedSource(
    _ renderImages: EditingCanvasRenderImages,
    drawable: CAMetalDrawable,
    descriptor: MTLRenderPassDescriptor,
    commandBuffer: MTLCommandBuffer
  ) -> EditingCanvasViewportRenderPath {
    let pixelWidth = drawable.texture.width
    let pixelHeight = drawable.texture.height
    guard
      pixelWidth > 0,
      pixelHeight > 0,
      let sourceImage = viewportSourceImage(
        renderImages.source,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight
      )
    else {
      clearCurrentDrawable()
      return .clear
    }

    // The full source extent in drawable pixels: diagonal-based radii resolve
    // against this so they stay a fixed fraction of the source regardless of
    // zoom, instead of tracking the zoomed visible extent of `sourceImage`.
    let radiusReferenceExtent = viewportRadiusReferenceExtent(
      sourceExtent: renderImages.source.extent,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight
    )

    let baseImage = EditingCanvasImageProcessing.clippedToSourceAlpha(
      renderImages.effects
        .applyIgnoringFailure(to: sourceImage, radiusReferenceExtent: radiusReferenceExtent)
        .cropped(to: sourceImage.extent),
      source: sourceImage
    )

    renderDrawableImage(
      baseImage,
      drawable: drawable,
      descriptor: descriptor,
      commandBuffer: commandBuffer
    )
    return .cachedSourceBase
  }

  /// Invalidates ONLY the viewport-scoped layer cache. This runs on every
  /// viewport change (rotation / pan / zoom), so it must NOT drop the
  /// content-scoped bake (`preparedContentLayers`) — that survives viewport
  /// changes and is dropped separately by `invalidatePreparedContentLayers`
  /// when the render images themselves change.
  private func invalidateViewportCoreImageLayerCaches() {
    viewportState.preparedLayersCache = nil
  }

  /// Drops the content-scoped base/adjusted bake. Only the render-images
  /// generation (and the cached-source mode that reinterprets it) changes the
  /// baked content, so only those call this — NOT viewport updates.
  private func invalidatePreparedContentLayers() {
    viewportState.preparedContentLayers = nil
  }

  /// Texture-backed bake of the current `adjusted` (local-effect) layer, built
  /// once per render-images generation. The cache is cleared in
  /// `invalidatePreparedContentLayers` — i.e. ONLY on `setRenderImages` /
  /// `setViewportCachedSourceEnabled`, never on viewport changes — so the
  /// composite path samples it instead of re-evaluating the blur graph, which is
  /// invariant across viewport-only changes like rotation.
  ///
  /// Returns `nil` when there is no distinct local effect (`adjusted === base`)
  /// or no Metal device: in those cases the caller uses the live `base` graph,
  /// which is pointwise on the GPU-resident source and cheap to re-evaluate.
  private func preparedAdjustedLayer(
    _ renderImages: EditingCanvasRenderImages
  ) -> CIImage? {
    guard renderImages.adjusted !== renderImages.base else {
      return nil
    }
    if let cache = viewportState.preparedContentLayers {
      return cache.adjustedImage
    }
    guard let device else {
      return nil
    }
    #if DEBUG
    performanceDiagnostics.recordCacheMiss(.preparedContentLayers)
    #endif

    // Cap the bake at the editing-source resolution: detail beyond it does not
    // exist, so this is visually lossless for the fit-to-frame preview while
    // bounding the texture memory the bake holds for the gesture's duration.
    guard
      let bake = EditingCanvasContentBake.bake(
        renderImages.adjusted,
        cap: EditingCanvasImageProcessing.contentBakeMaxPixelSize,
        device: device,
        commandQueue: commandQueue,
        ciContext: ciContext,
        pixelFormat: EditingCanvasImageProcessing.colorTextureFormat,
        colorSpace: EditingCanvasImageProcessing.intermediateColorSpace
      )
    else {
      return nil
    }

    viewportState.preparedContentLayers = .init(
      adjustedTexture: bake.texture,
      adjustedImage: bake.image
    )
    return bake.image
  }

  private func viewportSourceImage(
    _ source: CIImage,
    pixelWidth: Int,
    pixelHeight: Int
  ) -> CIImage? {
    let key = EditingCanvasViewportSourceTextureKey(
      sourceExtent: source.extent,
      visibleContentRect: viewportState.visibleContentRect,
      visibleCanvasFrame: viewportState.visibleCanvasFrame,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight
    )
    if let cachedSource = viewportState.sourceTexture, cachedSource.key == key {
      return cachedSource.image
    }
    #if DEBUG
    performanceDiagnostics.recordCacheMiss(.sourceTexture)
    #endif

    guard
      let sourceTexture = makeRenderTexture(
        pixelFormat: EditingCanvasImageProcessing.colorTextureFormat,
        width: pixelWidth,
        height: pixelHeight
      ),
      let commandBuffer = commandQueue.makeCommandBuffer()
    else {
      return nil
    }

    encodeClearTexture(sourceTexture, commandBuffer: commandBuffer)
    renderViewportImage(source, into: sourceTexture, commandBuffer: commandBuffer)
    // No CPU wait: every consumer samples this texture through `ciContext`,
    // which encodes onto the same command queue, so GPU-side ordering already
    // guarantees the fill completes before any dependent render. Blocking here
    // stalled the main thread for a full GPU round-trip on every cache miss —
    // and zoom/pan invalidates this cache every frame.
    commandBuffer.commit()

    guard let sourceImage = CIImage(
      mtlTexture: sourceTexture,
      options: [.colorSpace: EditingCanvasImageProcessing.intermediateColorSpace]
    ) else {
      return nil
    }
    let renderBounds = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
    guard
      let sourceContentFrame = viewportTextureContentFrame(
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight
      )?.intersection(renderBounds),
      sourceContentFrame.isEmpty == false
    else {
      return nil
    }

    let cachedSource = EditingCanvasViewportSourceTexture(
      key: key,
      texture: sourceTexture,
      image: sourceImage.cropped(to: sourceContentFrame)
    )
    viewportState.sourceTexture = cachedSource
    return cachedSource.image
  }

  private func renderDrawableImage(
    _ image: CIImage,
    drawable: CAMetalDrawable,
    descriptor: MTLRenderPassDescriptor,
    commandBuffer: MTLCommandBuffer
  ) {
    descriptor.colorAttachments[0].loadAction = .clear
    descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    descriptor.colorAttachments[0].storeAction = .store
    commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)?.endEncoding()

    let renderBounds = CGRect(
      x: 0,
      y: 0,
      width: drawable.texture.width,
      height: drawable.texture.height
    )
    let drawableImage = image
      .transformed(by: CGAffineTransform(scaleX: 1, y: -1))
      .transformed(by: CGAffineTransform(translationX: 0, y: renderBounds.height))
      .cropped(to: renderBounds)

    ciContext.render(
      drawableImage,
      to: drawable.texture,
      commandBuffer: commandBuffer,
      bounds: renderBounds,
      colorSpace: EditingCanvasImageProcessing.drawableColorSpace
    )
    commandBuffer.commit()
    commandBuffer.waitUntilScheduled()
    drawable.present()
  }

  private func renderViewportCoreImageComposite(
    _ renderImages: EditingCanvasRenderImages,
    drawable: CAMetalDrawable,
    descriptor: MTLRenderPassDescriptor,
    commandBuffer: MTLCommandBuffer
  ) {
    let pixelWidth = drawable.texture.width
    let pixelHeight = drawable.texture.height
    guard pixelWidth > 0, pixelHeight > 0 else {
      clearCurrentDrawable()
      return
    }

    let renderBounds = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)

    guard
      let preparedLayers = viewportPreparedLayers(
        renderImages,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        renderBounds: renderBounds
      )
    else {
      clearCurrentDrawable()
      return
    }
    let baseImage = preparedLayers.baseImage
    let adjustedImage = preparedLayers.adjustedImage

    // Committed AND in-flight strokes rasterize through the SAME Metal stamp
    // shader every frame — no cache, no intermediate full-canvas texture. The
    // shared `brushStampAlpha` falloff matches the parametric export kernel, and
    // the pipeline's `.max` blend mirrors the export's `componentMax`
    // accumulation, so the live mask agrees with export by construction. Memory
    // is bounded by the viewport-sized mask texture.
    guard
      hasRenderableStroke(in: viewportState.visibleContentRect),
      let textures = viewportTextures(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    else {
      clearCurrentDrawable()
      return
    }
    encodeClearTexture(textures.maskTexture, commandBuffer: commandBuffer)
    encodeStrokeMaskForViewport(into: textures.maskTexture, commandBuffer: commandBuffer)
    guard
      let maskImage = CIImage(
        mtlTexture: textures.maskTexture,
        options: [.colorSpace: EditingCanvasImageProcessing.maskColorSpace]
      )?.cropped(to: renderBounds)
    else {
      clearCurrentDrawable()
      return
    }

    let compositedImage = adjustedImage
      .applyingFilter(
        "CIBlendWithAlphaMask",
        parameters: [
          kCIInputBackgroundImageKey: baseImage,
          kCIInputMaskImageKey: maskImage,
        ]
      )
      .cropped(to: renderBounds)

    renderDrawableImage(
      compositedImage,
      drawable: drawable,
      descriptor: descriptor,
      commandBuffer: commandBuffer
    )
  }

  /// Returns viewport-resolution bakes of the prepared base/adjusted images,
  /// reusing the cached textures when the viewport and drawable size are
  /// unchanged since the last bake. `setRenderImages`, viewport changes, and
  /// drawable-size changes invalidate the cache, so a cache hit is guaranteed
  /// to represent the current render images. Cached textures are filled and
  /// consumed through `ciContext` on the same command queue, so cross-frame
  /// reuse needs no CPU synchronization (same pattern as the cached-source
  /// layer caches).
  ///
  /// The bake is committed in its own command buffer before the cache entry is
  /// published; encoding into the caller's frame buffer would poison the cache
  /// with never-filled textures whenever the frame is abandoned before commit.
  private func viewportPreparedLayers(
    _ renderImages: EditingCanvasRenderImages,
    pixelWidth: Int,
    pixelHeight: Int,
    renderBounds: CGRect
  ) -> EditingCanvasViewportPreparedLayersCache? {
    let key = EditingCanvasViewportPreparedLayersCacheKey(
      visibleContentRect: viewportState.visibleContentRect,
      visibleCanvasFrame: viewportState.visibleCanvasFrame,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight
    )
    if let cache = viewportState.preparedLayersCache, cache.key == key {
      return cache
    }
    #if DEBUG
    performanceDiagnostics.recordCacheMiss(.preparedLayers)
    #endif

    guard
      let baseTexture = makeRenderTexture(
        pixelFormat: EditingCanvasImageProcessing.colorTextureFormat,
        width: pixelWidth,
        height: pixelHeight
      ),
      let adjustedTexture = makeRenderTexture(
        pixelFormat: EditingCanvasImageProcessing.colorTextureFormat,
        width: pixelWidth,
        height: pixelHeight
      ),
      let fillCommandBuffer = commandQueue.makeCommandBuffer()
    else {
      return nil
    }

    // The blur-heavy `adjusted` layer is sampled from its once-per-generation
    // bake, so this per-frame fill is a cheap affine resample instead of a full
    // re-evaluation of the blur graph. `base` stays the live graph — it is
    // pointwise on the GPU-resident source, so re-evaluating it per frame is
    // cheap and avoids holding a second large texture.
    let adjustedContent = preparedAdjustedLayer(renderImages) ?? renderImages.adjusted

    encodeClearTexture(baseTexture, commandBuffer: fillCommandBuffer)
    encodeClearTexture(adjustedTexture, commandBuffer: fillCommandBuffer)
    renderViewportImage(renderImages.base, into: baseTexture, commandBuffer: fillCommandBuffer)
    renderViewportImage(adjustedContent, into: adjustedTexture, commandBuffer: fillCommandBuffer)
    // No CPU wait: consumers sample these textures through `ciContext` on the
    // same command queue, so GPU-side ordering suffices.
    fillCommandBuffer.commit()

    guard
      let baseImage = CIImage(
        mtlTexture: baseTexture,
        options: [.colorSpace: EditingCanvasImageProcessing.intermediateColorSpace]
      )?.cropped(to: renderBounds),
      let adjustedImage = CIImage(
        mtlTexture: adjustedTexture,
        options: [.colorSpace: EditingCanvasImageProcessing.intermediateColorSpace]
      )?.cropped(to: renderBounds)
    else {
      return nil
    }

    let cache = EditingCanvasViewportPreparedLayersCache(
      key: key,
      baseTexture: baseTexture,
      adjustedTexture: adjustedTexture,
      baseImage: baseImage,
      adjustedImage: adjustedImage
    )
    viewportState.preparedLayersCache = cache
    return cache
  }

  private func renderViewportImage(
    _ image: CIImage,
    into texture: MTLTexture,
    commandBuffer: MTLCommandBuffer
  ) {
    let renderBounds = CGRect(
      x: 0,
      y: 0,
      width: texture.width,
      height: texture.height
    )
    guard let destinationFrame = viewportTextureContentFrame(
      pixelWidth: texture.width,
      pixelHeight: texture.height
    ) else {
      return
    }
    let scaleX = destinationFrame.width / viewportState.visibleContentRect.width
    let scaleY = destinationFrame.height / viewportState.visibleContentRect.height
    let visibleImage = image
      .transformed(
        by: CGAffineTransform(
          translationX: -viewportState.visibleContentRect.minX,
          y: -viewportState.visibleContentRect.minY
        )
      )
      .transformed(
        by: CGAffineTransform(
          scaleX: scaleX,
          y: scaleY
        )
      )
      .transformed(
        by: CGAffineTransform(
          translationX: destinationFrame.minX,
          y: destinationFrame.minY
        )
      )
      .cropped(to: renderBounds)

    ciContext.render(
      visibleImage,
      to: texture,
      commandBuffer: commandBuffer,
      bounds: renderBounds,
      colorSpace: EditingCanvasImageProcessing.intermediateColorSpace
    )
  }

  private func viewportTextureContentFrame(pixelWidth: Int, pixelHeight: Int) -> CGRect? {
    guard bounds.width > 0, bounds.height > 0 else {
      return nil
    }

    let drawableScaleX = CGFloat(pixelWidth) / bounds.width
    let drawableScaleY = CGFloat(pixelHeight) / bounds.height
    let frame = CGRect(
      x: viewportState.visibleCanvasFrame.minX * drawableScaleX,
      y: viewportState.visibleCanvasFrame.minY * drawableScaleY,
      width: viewportState.visibleCanvasFrame.width * drawableScaleX,
      height: viewportState.visibleCanvasFrame.height * drawableScaleY
    )
      .standardized

    guard frame.isNull == false, frame.isEmpty == false else {
      return nil
    }

    return frame
  }

  private func viewportTextures(
    pixelWidth: Int,
    pixelHeight: Int
  ) -> EditingCanvasViewportRenderTextures? {
    if let textures = viewportState.renderTextures,
       textures.pixelWidth == pixelWidth,
       textures.pixelHeight == pixelHeight
    {
      return textures
    }
    #if DEBUG
    performanceDiagnostics.recordCacheMiss(.renderTextures)
    #endif

    guard
      let maskTexture = makeRenderTexture(
        pixelFormat: .rgba8Unorm,
        width: pixelWidth,
        height: pixelHeight
      )
    else {
      return nil
    }

    let textures = EditingCanvasViewportRenderTextures(
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      maskTexture: maskTexture
    )
    viewportState.renderTextures = textures
    return textures
  }

  private func makeRenderTexture(
    pixelFormat: MTLPixelFormat,
    width: Int,
    height: Int
  ) -> MTLTexture? {
    guard let device else {
      return nil
    }

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: pixelFormat,
      width: width,
      height: height,
      mipmapped: false
    )
    descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
    descriptor.storageMode = .private
    return device.makeTexture(descriptor: descriptor)
  }

  /// Rasterizes the committed strokes AND the in-flight (active) stroke into the
  /// viewport mask texture, live every frame — no cache, no intermediate
  /// full-canvas texture. Stamps accumulate with `max` (`brushMaskPipeline`) and
  /// use the shared `brushStampAlpha` falloff, so the result matches the
  /// parametric export kernel's `componentMax` rasterization by construction.
  /// Cost is O(visible stamp coverage); only stamps intersecting the viewport
  /// are drawn.
  private func encodeStrokeMaskForViewport(
    into texture: MTLTexture,
    commandBuffer: MTLCommandBuffer
  ) {
    let visible = viewportState.visibleContentRect
    let viewportFrame = viewportState.visibleCanvasFrame
    guard
      hasRenderableStroke(in: visible),
      visible.width > 0, visible.height > 0,
      viewportFrame.width > 0, viewportFrame.height > 0,
      bounds.width > 0, bounds.height > 0
    else {
      return
    }

    let drawableScaleX = CGFloat(texture.width) / bounds.width
    let drawableScaleY = CGFloat(texture.height) / bounds.height
    let contentToViewScaleX = viewportFrame.width / visible.width
    let contentToViewScaleY = viewportFrame.height / visible.height
    let pixelScaleX = contentToViewScaleX * drawableScaleX
    let pixelScaleY = contentToViewScaleY * drawableScaleY
    let targetSize = SIMD2(Float(texture.width), Float(texture.height))

    let descriptor = MTLRenderPassDescriptor()
    descriptor.colorAttachments[0].texture = texture
    descriptor.colorAttachments[0].loadAction = .load
    descriptor.colorAttachments[0].storeAction = .store

    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
      return
    }

    encoder.setRenderPipelineState(brushMaskPipeline)

    func encode(stamps: [CGPoint], brush: EditingCanvasBrush) {
      let radius = CGFloat(brush.size / 2)
      let pixelRadius = Float(Double(radius) * Double((pixelScaleX + pixelScaleY) * 0.5))
      let hardness = Float(brush.hardness)
      let opacity = Float(brush.opacity)

      for stamp in stamps where stampIntersectsVisibleRect(stamp, radius: radius, visible: visible) {
        var uniforms = BrushStampUniforms(
          canvasSize: targetSize,
          center: SIMD2(
            Float((viewportFrame.minX + (stamp.x - visible.minX) * contentToViewScaleX) * drawableScaleX),
            Float((viewportFrame.minY + (stamp.y - visible.minY) * contentToViewScaleY) * drawableScaleY)
          ),
          radius: pixelRadius,
          hardness: hardness,
          opacity: opacity
        )
        encoder.setVertexBytes(
          &uniforms,
          length: MemoryLayout<BrushStampUniforms>.stride,
          index: 0
        )
        encoder.setFragmentBytes(
          &uniforms,
          length: MemoryLayout<BrushStampUniforms>.stride,
          index: 0
        )
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
      }
    }

    // Committed strokes share the active stroke's canvas-content coordinate space
    // and the same shader, so they render in the same pass with `.max` blend.
    for record in strokeState.committedRecords where record.stamps.isEmpty == false {
      encode(stamps: record.stamps, brush: record.brush)
    }

    if let activeBrush = strokeState.activeBrush, strokeState.activeStamps.isEmpty == false {
      encode(stamps: strokeState.activeStamps, brush: activeBrush)
    }

    encoder.endEncoding()
  }

  /// Whether any committed or in-flight stroke intersects the viewport. Gates the
  /// composite render path (committed strokes show through the parametric mask
  /// even with no active stroke).
  private func hasRenderableStroke(in canvasRect: CGRect) -> Bool {
    if hasRenderableActiveStroke(in: canvasRect) {
      return true
    }

    return strokeState.committedRecords.contains { stroke in
      stroke.bounds.intersects(canvasRect) && stroke.stamps.isEmpty == false
    }
  }

  /// Whether the in-flight (active) stroke has stamps intersecting the viewport.
  private func hasRenderableActiveStroke(in canvasRect: CGRect) -> Bool {
    guard let activeBrush = strokeState.activeBrush else {
      return false
    }
    return strokeState.activeStamps.contains {
      stampIntersectsVisibleRect(
        $0,
        radius: CGFloat(activeBrush.size / 2),
        visible: canvasRect
      )
    }
  }

  private func stampIntersectsVisibleRect(
    _ stamp: CGPoint,
    radius: CGFloat,
    visible: CGRect
  ) -> Bool {
    let stampMinX = stamp.x - radius
    let stampMinY = stamp.y - radius
    let stampMaxX = stamp.x + radius
    let stampMaxY = stamp.y + radius
    return stampMaxX >= visible.minX
      && stampMinX <= visible.maxX
      && stampMaxY >= visible.minY
      && stampMinY <= visible.maxY
  }

  private func clearCurrentDrawable() {
    guard
      let drawable = currentDrawable,
      let descriptor = currentRenderPassDescriptor,
      let commandBuffer = commandQueue.makeCommandBuffer()
    else {
      return
    }

    descriptor.colorAttachments[0].texture = drawable.texture
    descriptor.colorAttachments[0].loadAction = .clear
    descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    descriptor.colorAttachments[0].storeAction = .store
    commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)?.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilScheduled()
    drawable.present()
  }

  private static func makeBrushMaskPipeline(
    device: MTLDevice,
    library: MTLLibrary
  ) throws -> MTLRenderPipelineState {
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "brushStampVertex")
    descriptor.fragmentFunction = library.makeFunction(name: "brushStampFragment")
    descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
    descriptor.colorAttachments[0].isBlendingEnabled = true
    // Overlapping stamps within the active stroke take the per-channel maximum,
    // matching the parametric mask's `CIBlendKernel.componentMax` accumulation
    // (FeatureGraphCompiler.render(_:BrushMask)). Metal ignores the blend factors
    // for `.max`, but they are set to `.one` for clarity.
    descriptor.colorAttachments[0].rgbBlendOperation = .max
    descriptor.colorAttachments[0].alphaBlendOperation = .max
    descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
    descriptor.colorAttachments[0].destinationRGBBlendFactor = .one
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
    descriptor.colorAttachments[0].destinationAlphaBlendFactor = .one
    return try device.makeRenderPipelineState(descriptor: descriptor)
  }

  private static func makeBrushMaskShaderLibrary(device: MTLDevice) throws -> MTLLibrary {
    // The compiled library lives in BrightroomParametric so the live shader and
    // the parametric export kernel are built as one brush-mask rasterization family.
    return try device.makeLibrary(URL: BrushStampMetalLibrary.url())
  }
}
