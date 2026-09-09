import CoreImage
import BrightroomEngine
import BrightroomParametric
import MetalKit
import simd
import UIKit

private struct EditingCanvasViewportSourceTextureKey: Equatable {
  var sourceExtent: CGRect
  var visibleContentRect: CGRect
  var contentToCanvasTransform: CGAffineTransform
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
  var contentToCanvasTransform: CGAffineTransform
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
/// Only `adjusted` is baked. The base effect graph remains lazy and is evaluated
/// for each viewport, avoiding a second retained content-sized texture. Global
/// effects are an open pipeline, so that evaluation is not necessarily cheap.
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

  /// Maps y-down image-content coordinates into the fixed canvas's point space.
  ///
  /// `visibleContentRect` is a conservative content-space bound for culling;
  /// `contentToCanvasTransform` alone determines placement through translation,
  /// rotation, and uniform scale; the brush remains circular in this geometry.
  /// The host samples presentation geometry immediately before drawing, without
  /// changing the canvas's frame or moving it into the animated scroll hierarchy.
  struct Viewport {
    var visibleContentRect: CGRect
    var contentToCanvasTransform: CGAffineTransform

    /// The transformed content bounds, for diagnostics and coarse intersection.
    /// Rotation makes this an enclosing rectangle, not a rendering transform.
    var visibleCanvasFrame: CGRect {
      visibleContentRect.applying(contentToCanvasTransform)
    }

    /// Resolves content coordinates into y-down texture pixels. The caller
    /// supplies positive canvas and texture sizes for the current drawable.
    func contentToTextureTransform(
      canvasSize: CGSize,
      textureSize: CGSize
    ) -> CGAffineTransform {
      contentToCanvasTransform.concatenating(CGAffineTransform(
        scaleX: textureSize.width / canvasSize.width,
        y: textureSize.height / canvasSize.height
      ))
    }

    /// Scales a circular content-space radius into texture pixels without
    /// letting rotation inflate it through an axis-aligned bounding box.
    /// Scroll-view geometry uses uniform scale and rotation; averaging the two
    /// basis lengths also accommodates drawable-size pixel rounding.
    func textureRadius(
      forContentRadius radius: CGFloat,
      canvasSize: CGSize,
      textureSize: CGSize
    ) -> CGFloat {
      let transform = contentToTextureTransform(canvasSize: canvasSize, textureSize: textureSize)
      let scale = (hypot(transform.a, transform.b) + hypot(transform.c, transform.d)) * 0.5
      return radius * scale
    }
  }

  private typealias BrushStampUniforms = BrushMaskPipeline.StampUniforms
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
    var viewport: Viewport

    init(canvasSize: CGSize) {
      self.viewport = Viewport(
        visibleContentRect: CGRect(origin: .zero, size: canvasSize),
        contentToCanvasTransform: .init(scaleX: 0, y: 0)
      )
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

  /// CADisplayLink state for live stroke refreshes.
  private struct LiveRefreshState: ~Copyable {
    var displayLink: CADisplayLink?
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
  #if DEBUG
  private var performanceDiagnostics = PerformanceDiagnostics()
  #endif
  private var isExternallyFrameDriven = false
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
      self.brushMaskPipeline = try BrushMaskPipeline.make(device: device)
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

  isolated deinit {
    stopLiveDisplayLink()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()

    guard window != nil else {
      // Invariant: leaving the window severs the display-link retain chain.
      // `deinit` alone cannot, because the run loop retains the link and the
      // link retains its target — so a live stroke keeps this view, and its
      // rgba16Float texture caches, alive and ticking forever. Teardown can
      // land mid-stroke (canvas-size change, focus switch during a touch)
      // because the drawing gesture recognizer lives on the container, not
      // here, so the owner does not necessarily cancel the stroke first.
      cancelActiveStroke()
      // Restated rather than left implicit: stopping the link is the standing
      // guarantee of this path, not a side effect of stroke bookkeeping.
      stopLiveDisplayLink()
      return
    }

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
      scheduleDisplayIfNeeded()
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
    scheduleDisplayIfNeeded()
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
    scheduleDisplayIfNeeded()
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
    scheduleDisplayIfNeeded()
  }

  /// Transfers frame scheduling to a host that calls `draw()` on every visible
  /// display-link tick. The host owns pausing that loop offscreen/background;
  /// this view keeps consuming stroke work in the same draw pass as its viewport.
  /// Standalone hosts retain on-demand draws and the stroke-only display link.
  func setExternalFrameDrivingEnabled(_ isEnabled: Bool) {
    guard isExternallyFrameDriven != isEnabled else { return }

    isExternallyFrameDriven = isEnabled
    enableSetNeedsDisplay = isEnabled == false
    if isEnabled {
      isPaused = true
      stopLiveDisplayLink()
    } else {
      if strokeState.activeBrush != nil {
        startLiveDisplayLinkIfNeeded()
      }
      scheduleDisplayIfNeeded()
    }
  }

  private func scheduleDisplayIfNeeded() {
    guard isExternallyFrameDriven == false else { return }
    setNeedsDisplay()
  }

  /// Updates the sampled viewport. A host that draws once per display-link tick
  /// can disable scheduling and call `draw()` after applying all frame inputs.
  func setViewport(_ viewport: Viewport, schedulesDisplay: Bool = true) {
    updateViewport(viewport, schedulesDisplay: schedulesDisplay)
  }

  private func updateViewport(
    _ viewport: Viewport,
    schedulesDisplay: Bool
  ) {
    let transform = viewport.contentToCanvasTransform
    guard
      transform.a.isFinite, transform.b.isFinite,
      transform.c.isFinite, transform.d.isFinite,
      transform.tx.isFinite, transform.ty.isFinite,
      transform.a * transform.d - transform.b * transform.c != 0
    else {
      return
    }

    var nextViewport = viewport
    let canvasRect = CGRect(origin: .zero, size: canvasSize)
    nextViewport.visibleContentRect = viewport.visibleContentRect.intersection(canvasRect)
    let didChangeViewport = viewportState.viewport.visibleContentRect != nextViewport.visibleContentRect
      || viewportState.viewport.contentToCanvasTransform != transform
    guard didChangeViewport else {
      return
    }

    // An empty intersection must replace the previous viewport so an image
    // dragged completely out of sight clears instead of keeping a stale frame.
    viewportState.viewport = nextViewport
    viewportState.sourceTexture = nil
    // The mask texture's allocation depends only on drawable size; each draw
    // clears and rasterizes it, so changing the viewport can reuse the storage.
    invalidateViewportCoreImageLayerCaches()
    #if DEBUG
    performanceDiagnostics.recordInvalidation(.viewport)
    #endif
    if schedulesDisplay {
      scheduleDisplayIfNeeded()
    }
  }

  func reset() {
    cancelActiveStroke()
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
    scheduleDisplayIfNeeded()
  }

  func draw(in view: MTKView) {
    if isExternallyFrameDriven, strokeState.pendingLiveStamps.isEmpty == false {
      strokeState.pendingLiveStamps.removeAll(keepingCapacity: true)
    }
    renderViewportImage()
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
    scheduleDisplayIfNeeded()
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
      scheduleDisplayIfNeeded()
    }
  }

  private func commitActiveStroke() {
    guard let brush = strokeState.activeBrush, strokeState.activeStamps.isEmpty == false else {
      scheduleDisplayIfNeeded()
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
    scheduleDisplayIfNeeded()
  }

  private func startLiveDisplayLinkIfNeeded() {
    guard isExternallyFrameDriven == false, liveRefreshState.displayLink == nil else { return }

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
      scheduleDisplayIfNeeded()
    }
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
      viewportState.viewport.visibleContentRect.width > 0,
      viewportState.viewport.visibleContentRect.height > 0,
      viewportState.viewport.visibleCanvasFrame.width > 0,
      viewportState.viewport.visibleCanvasFrame.height > 0
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

    let hasRenderableStroke = hasRenderableStroke(in: viewportState.viewport.visibleContentRect)

    // Global effects are an open pipeline and may depend on direction, extent,
    // or position. Always evaluate them in content space through `base`, before
    // the viewport affine, so no pan/zoom/rotation can change their domain.
    // Sampling the source cache is equivalent only when global effects are idle.
    if viewportState.usesCachedSourceRendering,
       renderImages.usesPreparedBaseImage == false,
       renderImages.effects.hasEnabledEffects == false {
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
      // `base` already expresses the global effects in content coordinates.
      // Apply the viewport afterward so navigation preserves that effect domain.
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
      visibleContentRect: viewportState.viewport.visibleContentRect,
      visibleCanvasFrame: viewportState.viewport.visibleCanvasFrame
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
    let transform = viewportState.viewport.contentToTextureTransform(
      canvasSize: bounds.size,
      textureSize: renderBounds.size
    )
    let visibleImage = image
      .transformed(by: transform)
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

  /// Renders an unadjusted source through its viewport-resolution texture cache.
  /// Any enabled global or local effect uses a content-space prepared image.
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

    renderDrawableImage(
      sourceImage,
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
  /// or the bake is unavailable. The caller then evaluates `adjusted` lazily
  /// for the current viewport.
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
      visibleContentRect: viewportState.viewport.visibleContentRect,
      contentToCanvasTransform: viewportState.viewport.contentToCanvasTransform,
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
      hasRenderableStroke(in: viewportState.viewport.visibleContentRect),
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
      visibleContentRect: viewportState.viewport.visibleContentRect,
      contentToCanvasTransform: viewportState.viewport.contentToCanvasTransform,
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
    // bake, so its per-frame fill resamples the texture instead of re-evaluating
    // that effect graph. `base` remains lazy to avoid retaining a second large
    // content texture; its evaluation cost depends on the global effect pipeline.
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
    let transform = viewportState.viewport.contentToTextureTransform(
      canvasSize: bounds.size,
      textureSize: renderBounds.size
    )
    let visibleImage = image
      .transformed(by: transform)
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

    let transform = viewportState.viewport.contentToTextureTransform(
      canvasSize: bounds.size,
      textureSize: CGSize(width: pixelWidth, height: pixelHeight)
    )
    let frame = viewportState.viewport.visibleContentRect.applying(transform).standardized

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
    let viewport = viewportState.viewport
    let visible = viewport.visibleContentRect
    guard
      hasRenderableStroke(in: visible),
      visible.width > 0, visible.height > 0,
      bounds.width > 0, bounds.height > 0
    else {
      return
    }

    let textureSize = CGSize(width: texture.width, height: texture.height)
    let contentToTextureTransform = viewport.contentToTextureTransform(
      canvasSize: bounds.size,
      textureSize: textureSize
    )
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
      let pixelRadius = Float(viewport.textureRadius(
        forContentRadius: radius,
        canvasSize: bounds.size,
        textureSize: textureSize
      ))
      let hardness = Float(brush.hardness)
      let opacity = Float(brush.opacity)

      for stamp in stamps where stampIntersectsVisibleRect(stamp, radius: radius, visible: visible) {
        let center = stamp.applying(contentToTextureTransform)
        BrushMaskPipeline.encodeStamp(
          BrushStampUniforms(
            canvasSize: targetSize,
            center: SIMD2(
              Float(center.x),
              Float(center.y)
            ),
            radius: pixelRadius,
            hardness: hardness,
            opacity: opacity
          ),
          into: encoder
        )
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
}
