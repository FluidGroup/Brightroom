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

private struct EditingCanvasViewportCoreImageBaseLayerCacheKey: Equatable {
  var sourceExtent: CGRect
  var visibleContentRect: CGRect
  var visibleCanvasFrame: CGRect
  var pixelWidth: Int
  var pixelHeight: Int
  var effects: EffectPipeline
}

private struct EditingCanvasViewportCoreImageLocalLayerCacheKey: Equatable {
  var baseKey: EditingCanvasViewportCoreImageBaseLayerCacheKey
  var localEffect: EffectPipeline
}

private struct EditingCanvasViewportCoreImageBaseLayerCache {
  let key: EditingCanvasViewportCoreImageBaseLayerCacheKey
  let texture: MTLTexture
  let image: CIImage
}

private struct EditingCanvasViewportCoreImageLocalLayerCache {
  let key: EditingCanvasViewportCoreImageLocalLayerCacheKey
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

private enum EditingCanvasViewportRenderPath: String {
  case clear
  case baseImage = "base-image"
  case cachedSourceBase = "cached-source-base"
  case cachedSourceComposite = "cached-source-composite"
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
    var coreImageBaseLayerCache: EditingCanvasViewportCoreImageBaseLayerCache?
    var coreImageLocalLayerCache: EditingCanvasViewportCoreImageLocalLayerCache?
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
      case coreImageBaseLayer = "core-image-base-layer"
      case coreImageLocalLayer = "core-image-local-layer"
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
    var cachedSourceCompositeFrameCount = 0
    var coreImageCompositeFrameCount = 0
    var sourceTextureMissCount = 0
    var renderTexturesMissCount = 0
    var coreImageBaseLayerMissCount = 0
    var coreImageLocalLayerMissCount = 0
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
      case .coreImageBaseLayer:
        coreImageBaseLayerMissCount += 1
      case .coreImageLocalLayer:
        coreImageLocalLayerMissCount += 1
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
      case .cachedSourceComposite:
        cachedSourceCompositeFrameCount += 1
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
        path clear:\(clearFrameCount) base:\(baseImageFrameCount) cachedBase:\(cachedSourceBaseFrameCount) cachedComposite:\(cachedSourceCompositeFrameCount) coreComposite:\(coreImageCompositeFrameCount)
        cacheMiss source:\(sourceTextureMissCount) textures:\(renderTexturesMissCount) baseLayer:\(coreImageBaseLayerMissCount) localLayer:\(coreImageLocalLayerMissCount) preparedLayers:\(preparedLayersMissCount)
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
      cachedSourceCompositeFrameCount = 0
      coreImageCompositeFrameCount = 0
      sourceTextureMissCount = 0
      renderTexturesMissCount = 0
      coreImageBaseLayerMissCount = 0
      coreImageLocalLayerMissCount = 0
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
      options: [.name: "EditingCanvas"]
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
    colorPixelFormat = .bgra8Unorm
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

    reset()
  }

  @available(*, unavailable)
  required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    stopLiveDisplayLink()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
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
    #if DEBUG
    performanceDiagnostics.recordInvalidation(.cachedSourceMode)
    #endif
    setNeedsDisplay()
  }

  func setCommittedStrokes(_ records: [EditingCanvasStrokeRecord]) {
    // Hosts re-send committed strokes on every state update; identical records
    // would needlessly drop the mask texture and schedule a frame.
    guard strokeState.committedRecords != records else {
      return
    }

    strokeState.committedRecords = records
    viewportState.renderTextures = nil
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
        hasRenderableStroke: hasRenderableStroke,
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
      colorSpace: EditingCanvasImageProcessing.colorSpace
    )
    commandBuffer.commit()
    commandBuffer.waitUntilScheduled()
    drawable.present()
  }

  @discardableResult
  private func renderViewportCachedSource(
    _ renderImages: EditingCanvasRenderImages,
    hasRenderableStroke: Bool,
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

    let baseImage = EditingCanvasImageProcessing.clippedToSourceAlpha(
      renderImages.effects
        .applyIgnoringFailure(to: sourceImage)
        .cropped(to: sourceImage.extent),
      source: sourceImage
    )

    guard renderImages.hasLocalEffect,
          hasRenderableStroke
    else {
      renderDrawableImage(
        baseImage,
        drawable: drawable,
        descriptor: descriptor,
        commandBuffer: commandBuffer
      )
      return .cachedSourceBase
    }

    renderViewportCachedCoreImageComposite(
      baseImage: baseImage,
      sourceExtent: renderImages.source.extent,
      effects: renderImages.effects,
      localEffect: renderImages.localEffect,
      drawable: drawable,
      descriptor: descriptor,
      commandBuffer: commandBuffer
    )
    return .cachedSourceComposite
  }

  private func invalidateViewportCoreImageLayerCaches() {
    viewportState.coreImageBaseLayerCache = nil
    viewportState.coreImageLocalLayerCache = nil
    viewportState.preparedLayersCache = nil
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
        pixelFormat: .bgra8Unorm,
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
      options: [.colorSpace: EditingCanvasImageProcessing.colorSpace]
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
      colorSpace: EditingCanvasImageProcessing.colorSpace
    )
    commandBuffer.commit()
    commandBuffer.waitUntilScheduled()
    drawable.present()
  }

  private func renderViewportCachedCoreImageComposite(
    baseImage: CIImage,
    sourceExtent: CGRect,
    effects: EffectPipeline,
    localEffect: EffectPipeline,
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

    let textures = viewportTextures(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    guard let textures else {
      clearCurrentDrawable()
      return
    }

    encodeClearTexture(textures.maskTexture, commandBuffer: commandBuffer)
    encodeStrokeMaskForViewport(into: textures.maskTexture, commandBuffer: commandBuffer)

    let baseLayerKey = EditingCanvasViewportCoreImageBaseLayerCacheKey(
      sourceExtent: sourceExtent,
      visibleContentRect: viewportState.visibleContentRect,
      visibleCanvasFrame: viewportState.visibleCanvasFrame,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      effects: effects
    )

    guard
      let baseLayerImage = viewportCoreImageBaseLayerImage(
        baseImage,
        key: baseLayerKey,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight
      ),
      let adjustedLayerImage = viewportCoreImageLocalLayerImage(
        baseLayerImage,
        baseKey: baseLayerKey,
        localEffect: localEffect,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight
      )
    else {
      clearCurrentDrawable()
      return
    }

    guard let maskImage = CIImage(
      mtlTexture: textures.maskTexture,
      options: [.colorSpace: EditingCanvasImageProcessing.colorSpace]
    )?.cropped(to: baseLayerImage.extent) else {
      clearCurrentDrawable()
      return
    }

    let compositedImage = adjustedLayerImage
      .applyingFilter(
        "CIBlendWithAlphaMask",
        parameters: [
          kCIInputBackgroundImageKey: baseLayerImage,
          kCIInputMaskImageKey: maskImage,
        ]
      )
      .cropped(to: baseLayerImage.extent)

    renderDrawableImage(
      compositedImage,
      drawable: drawable,
      descriptor: descriptor,
      commandBuffer: commandBuffer
    )
  }

  private func viewportCoreImageBaseLayerImage(
    _ image: CIImage,
    key: EditingCanvasViewportCoreImageBaseLayerCacheKey,
    pixelWidth: Int,
    pixelHeight: Int
  ) -> CIImage? {
    if let cache = viewportState.coreImageBaseLayerCache, cache.key == key {
      return cache.image
    }
    #if DEBUG
    performanceDiagnostics.recordCacheMiss(.coreImageBaseLayer)
    #endif

    guard
      let texture = makeRenderTexture(
        pixelFormat: .bgra8Unorm,
        width: pixelWidth,
        height: pixelHeight
      ),
      let cachedImage = makeCachedViewportLayerImage(
        image,
        texture: texture
      )
    else {
      return nil
    }

    viewportState.coreImageBaseLayerCache = EditingCanvasViewportCoreImageBaseLayerCache(
      key: key,
      texture: texture,
      image: cachedImage
    )
    viewportState.coreImageLocalLayerCache = nil
    return cachedImage
  }

  private func viewportCoreImageLocalLayerImage(
    _ baseImage: CIImage,
    baseKey: EditingCanvasViewportCoreImageBaseLayerCacheKey,
    localEffect: EffectPipeline,
    pixelWidth: Int,
    pixelHeight: Int
  ) -> CIImage? {
    let key = EditingCanvasViewportCoreImageLocalLayerCacheKey(
      baseKey: baseKey,
      localEffect: localEffect
    )
    if let cache = viewportState.coreImageLocalLayerCache, cache.key == key {
      return cache.image
    }
    #if DEBUG
    performanceDiagnostics.recordCacheMiss(.coreImageLocalLayer)
    #endif

    let adjustedImage = EditingCanvasImageProcessing.clippedToSourceAlpha(
      localEffect
        .applyIgnoringFailure(to: baseImage)
        .cropped(to: baseImage.extent),
      source: baseImage
    )
    guard
      let texture = makeRenderTexture(
        pixelFormat: .bgra8Unorm,
        width: pixelWidth,
        height: pixelHeight
      ),
      let cachedImage = makeCachedViewportLayerImage(
        adjustedImage,
        texture: texture
      )
    else {
      return nil
    }

    viewportState.coreImageLocalLayerCache = EditingCanvasViewportCoreImageLocalLayerCache(
      key: key,
      texture: texture,
      image: cachedImage
    )
    return cachedImage
  }

  /// Bakes `image` into `texture` in a dedicated command buffer, committed
  /// before returning, so the texture is safe to publish in a cross-frame
  /// cache. Encoding into the caller's frame buffer would poison the cache
  /// with never-filled textures whenever the frame is abandoned before commit
  /// (e.g. `clearCurrentDrawable` after a later guard fails). No CPU wait:
  /// consumers sample the texture through `ciContext` on the same command
  /// queue, so GPU-side ordering suffices — sequential commits also keep the
  /// base-layer fill ahead of the local-layer fill that samples it.
  private func makeCachedViewportLayerImage(
    _ image: CIImage,
    texture: MTLTexture
  ) -> CIImage? {
    guard let fillCommandBuffer = commandQueue.makeCommandBuffer() else {
      return nil
    }
    encodeClearTexture(texture, commandBuffer: fillCommandBuffer)
    renderCachedViewportImage(image, into: texture, commandBuffer: fillCommandBuffer)
    fillCommandBuffer.commit()
    return CIImage(
      mtlTexture: texture,
      options: [.colorSpace: EditingCanvasImageProcessing.colorSpace]
    )?.cropped(to: cachedViewportLayerExtent(for: image, texture: texture))
  }

  private func renderCachedViewportImage(
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

    ciContext.render(
      image.cropped(to: renderBounds),
      to: texture,
      commandBuffer: commandBuffer,
      bounds: renderBounds,
      colorSpace: EditingCanvasImageProcessing.colorSpace
    )
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

    guard
      let textures = viewportTextures(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    else {
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

    encodeClearTexture(textures.maskTexture, commandBuffer: commandBuffer)
    encodeStrokeMaskForViewport(into: textures.maskTexture, commandBuffer: commandBuffer)

    guard
      let maskImage = CIImage(
        mtlTexture: textures.maskTexture,
        options: [.colorSpace: EditingCanvasImageProcessing.colorSpace]
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
        pixelFormat: .bgra8Unorm,
        width: pixelWidth,
        height: pixelHeight
      ),
      let adjustedTexture = makeRenderTexture(
        pixelFormat: .bgra8Unorm,
        width: pixelWidth,
        height: pixelHeight
      ),
      let fillCommandBuffer = commandQueue.makeCommandBuffer()
    else {
      return nil
    }

    encodeClearTexture(baseTexture, commandBuffer: fillCommandBuffer)
    encodeClearTexture(adjustedTexture, commandBuffer: fillCommandBuffer)
    renderViewportImage(renderImages.base, into: baseTexture, commandBuffer: fillCommandBuffer)
    renderViewportImage(renderImages.adjusted, into: adjustedTexture, commandBuffer: fillCommandBuffer)
    // No CPU wait: consumers sample these textures through `ciContext` on the
    // same command queue, so GPU-side ordering suffices.
    fillCommandBuffer.commit()

    guard
      let baseImage = CIImage(
        mtlTexture: baseTexture,
        options: [.colorSpace: EditingCanvasImageProcessing.colorSpace]
      )?.cropped(to: renderBounds),
      let adjustedImage = CIImage(
        mtlTexture: adjustedTexture,
        options: [.colorSpace: EditingCanvasImageProcessing.colorSpace]
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
      colorSpace: EditingCanvasImageProcessing.colorSpace
    )
  }

  private func cachedViewportLayerExtent(for image: CIImage, texture: MTLTexture) -> CGRect {
    let renderBounds = CGRect(x: 0, y: 0, width: texture.width, height: texture.height)
    let imageBounds = image.extent.intersection(renderBounds)
    if imageBounds.isNull == false, imageBounds.isEmpty == false {
      return imageBounds
    } else {
      return renderBounds
    }
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

    for stroke in strokeState.committedRecords where stroke.bounds.intersects(visible) {
      encode(stamps: stroke.stamps, brush: stroke.brush)
    }

    if let activeBrush = strokeState.activeBrush, strokeState.activeStamps.isEmpty == false {
      encode(stamps: strokeState.activeStamps, brush: activeBrush)
    }

    encoder.endEncoding()
  }

  private func hasRenderableStroke(in canvasRect: CGRect) -> Bool {
    if let activeBrush = strokeState.activeBrush,
       strokeState.activeStamps.contains(where: {
         stampIntersectsVisibleRect(
           $0,
           radius: CGFloat(activeBrush.size / 2),
           visible: canvasRect
         )
       })
    {
      return true
    }

    return strokeState.committedRecords.contains { stroke in
      stroke.bounds.intersects(canvasRect) && stroke.stamps.isEmpty == false
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
    descriptor.colorAttachments[0].rgbBlendOperation = .add
    descriptor.colorAttachments[0].alphaBlendOperation = .add
    descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
    descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
    descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
    return try device.makeRenderPipelineState(descriptor: descriptor)
  }

  private static func makeBrushMaskShaderLibrary(device: MTLDevice) throws -> MTLLibrary {
    try device.makeLibrary(source: EditingCanvasBrushMaskShaderSource.source, options: nil)
  }
}
