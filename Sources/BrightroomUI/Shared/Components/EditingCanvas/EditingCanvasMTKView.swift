import CoreImage
import BrightroomEngine
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
  var filters: EditingStack.Edit.Filters
}

private struct EditingCanvasViewportCoreImageLocalLayerCacheKey: Equatable {
  var baseKey: EditingCanvasViewportCoreImageBaseLayerCacheKey
  var localEffect: EditingStack.Edit.LocalAdjustmentEffect
  var previewScale: CGFloat
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

struct EditingCanvasRenderImages {
  let source: CIImage
  let filters: EditingStack.Edit.Filters
  let base: CIImage
  let adjusted: CIImage
  let localEffect: EditingStack.Edit.LocalAdjustmentEffect
  let usesPreparedBaseImage: Bool

  var hasLocalEffect: Bool {
    localEffect.isActive
  }
}

final class _EditingCanvasMTKView: MTKView, MTKViewDelegate {

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

  private let canvasSize: CGSize
  private let commandQueue: MTLCommandQueue
  private let brushMaskPipeline: MTLRenderPipelineState
  private var viewportState: ViewportState
  private var strokeState = StrokeState()
  private var liveRefreshState = LiveRefreshState()
  private var drawMetrics = DrawMetrics()
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
    viewportState.renderTextures = nil
    invalidateViewportCoreImageLayerCaches()
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
    setNeedsDisplay()
  }

  func setCommittedStrokes(_ records: [EditingCanvasStrokeRecord]) {
    strokeState.committedRecords = records
    viewportState.renderTextures = nil
    setNeedsDisplay()
  }

  func setViewport(
    visibleContentRect rect: CGRect,
    visibleCanvasFrame frame: CGRect,
    zoomScale: CGFloat
  ) {
    let canvasRect = CGRect(origin: .zero, size: canvasSize)
    let nextRect = rect.intersection(canvasRect)
    let nextFrame = frame

    guard nextRect.isNull == false, nextRect.isEmpty == false else {
      return
    }

    let didChangeViewport = viewportState.visibleContentRect.equalTo(nextRect) == false
      || viewportState.visibleCanvasFrame.equalTo(nextFrame) == false
    guard didChangeViewport else {
      setNeedsDisplay()
      return
    }

    viewportState.visibleContentRect = nextRect
    viewportState.visibleCanvasFrame = nextFrame
    viewportState.sourceTexture = nil
    viewportState.renderTextures = nil
    invalidateViewportCoreImageLayerCaches()
    setNeedsDisplay()
    onMetricsChange?()
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
    setNeedsDisplay()
  }

  func draw(in view: MTKView) {
    defer {
      recordDrawSample()
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
      return
    }

    guard viewportState.usesCachedSourceRendering == false || renderImages.usesPreparedBaseImage else {
      renderViewportCachedSource(
        renderImages,
        drawable: drawable,
        descriptor: descriptor,
        commandBuffer: commandBuffer
      )
      return
    }

    guard renderImages.hasLocalEffect,
          hasRenderableStroke(in: viewportState.visibleContentRect)
    else {
      renderViewportBaseImage(
        renderImages.base,
        drawable: drawable,
        descriptor: descriptor,
        commandBuffer: commandBuffer
      )
      return
    }

    renderViewportCoreImageComposite(
      renderImages,
      drawable: drawable,
      descriptor: descriptor,
      commandBuffer: commandBuffer
    )
  }

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
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }

  private func renderViewportCachedSource(
    _ renderImages: EditingCanvasRenderImages,
    drawable: CAMetalDrawable,
    descriptor: MTLRenderPassDescriptor,
    commandBuffer: MTLCommandBuffer
  ) {
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
      return
    }

    let baseImage = EditingCanvasImageProcessing.clippedToSourceAlpha(
      renderImages.filters
        .apply(to: sourceImage)
        .cropped(to: sourceImage.extent),
      source: sourceImage
    )

    guard renderImages.hasLocalEffect,
          hasRenderableStroke(in: viewportState.visibleContentRect)
    else {
      renderDrawableImage(
        baseImage,
        drawable: drawable,
        descriptor: descriptor,
        commandBuffer: commandBuffer
      )
      return
    }

    renderViewportCachedCoreImageComposite(
      baseImage: baseImage,
      sourceExtent: renderImages.source.extent,
      filters: renderImages.filters,
      localEffect: renderImages.localEffect,
      drawable: drawable,
      descriptor: descriptor,
      commandBuffer: commandBuffer
    )
  }

  private func viewportPreviewScale(
    pixelWidth: Int,
    pixelHeight: Int
  ) -> CGFloat {
    guard
      bounds.width > 0,
      bounds.height > 0,
      viewportState.visibleContentRect.width > 0,
      viewportState.visibleContentRect.height > 0,
      viewportState.visibleCanvasFrame.width > 0,
      viewportState.visibleCanvasFrame.height > 0
    else {
      return 1
    }

    let drawableScaleX = CGFloat(pixelWidth) / bounds.width
    let drawableScaleY = CGFloat(pixelHeight) / bounds.height
    let pixelScaleX = viewportState.visibleCanvasFrame.width * drawableScaleX / viewportState.visibleContentRect.width
    let pixelScaleY = viewportState.visibleCanvasFrame.height * drawableScaleY / viewportState.visibleContentRect.height
    return max((pixelScaleX + pixelScaleY) * 0.5, 0.0001)
  }

  private func invalidateViewportCoreImageLayerCaches() {
    viewportState.coreImageBaseLayerCache = nil
    viewportState.coreImageLocalLayerCache = nil
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
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

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
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }

  private func renderViewportCachedCoreImageComposite(
    baseImage: CIImage,
    sourceExtent: CGRect,
    filters: EditingStack.Edit.Filters,
    localEffect: EditingStack.Edit.LocalAdjustmentEffect,
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

    let previewScale = viewportPreviewScale(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    let baseLayerKey = EditingCanvasViewportCoreImageBaseLayerCacheKey(
      sourceExtent: sourceExtent,
      visibleContentRect: viewportState.visibleContentRect,
      visibleCanvasFrame: viewportState.visibleCanvasFrame,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      filters: filters
    )

    guard
      let baseLayerImage = viewportCoreImageBaseLayerImage(
        baseImage,
        key: baseLayerKey,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        commandBuffer: commandBuffer
      ),
      let adjustedLayerImage = viewportCoreImageLocalLayerImage(
        baseLayerImage,
        baseKey: baseLayerKey,
        localEffect: localEffect,
        previewScale: previewScale,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        commandBuffer: commandBuffer
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
    pixelHeight: Int,
    commandBuffer: MTLCommandBuffer
  ) -> CIImage? {
    if let cache = viewportState.coreImageBaseLayerCache, cache.key == key {
      return cache.image
    }

    guard
      let texture = makeRenderTexture(
        pixelFormat: .bgra8Unorm,
        width: pixelWidth,
        height: pixelHeight
      ),
      let cachedImage = makeCachedViewportLayerImage(
        image,
        texture: texture,
        commandBuffer: commandBuffer
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
    localEffect: EditingStack.Edit.LocalAdjustmentEffect,
    previewScale: CGFloat,
    pixelWidth: Int,
    pixelHeight: Int,
    commandBuffer: MTLCommandBuffer
  ) -> CIImage? {
    let key = EditingCanvasViewportCoreImageLocalLayerCacheKey(
      baseKey: baseKey,
      localEffect: localEffect,
      previewScale: previewScale
    )
    if let cache = viewportState.coreImageLocalLayerCache, cache.key == key {
      return cache.image
    }

    let adjustedImage = EditingCanvasImageProcessing.clippedToSourceAlpha(
      localEffect
        .apply(to: baseImage, previewScale: previewScale)
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
        texture: texture,
        commandBuffer: commandBuffer
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

  private func makeCachedViewportLayerImage(
    _ image: CIImage,
    texture: MTLTexture,
    commandBuffer: MTLCommandBuffer
  ) -> CIImage? {
    encodeClearTexture(texture, commandBuffer: commandBuffer)
    renderCachedViewportImage(image, into: texture, commandBuffer: commandBuffer)
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
      let textures = viewportTextures(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    else {
      clearCurrentDrawable()
      return
    }

    encodeClearTexture(textures.maskTexture, commandBuffer: commandBuffer)
    encodeClearTexture(baseTexture, commandBuffer: commandBuffer)
    encodeClearTexture(adjustedTexture, commandBuffer: commandBuffer)
    renderViewportImage(renderImages.base, into: baseTexture, commandBuffer: commandBuffer)
    renderViewportImage(renderImages.adjusted, into: adjustedTexture, commandBuffer: commandBuffer)
    encodeStrokeMaskForViewport(into: textures.maskTexture, commandBuffer: commandBuffer)

    let renderBounds = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
    guard
      let imageBounds = viewportTextureContentFrame(
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight
      )?.intersection(renderBounds),
      imageBounds.isEmpty == false
    else {
      clearCurrentDrawable()
      return
    }
    guard
      let baseImage = CIImage(
        mtlTexture: baseTexture,
        options: [.colorSpace: EditingCanvasImageProcessing.colorSpace]
      )?.cropped(to: imageBounds),
      let adjustedImage = CIImage(
        mtlTexture: adjustedTexture,
        options: [.colorSpace: EditingCanvasImageProcessing.colorSpace]
      )?.cropped(to: imageBounds),
      let maskImage = CIImage(
        mtlTexture: textures.maskTexture,
        options: [.colorSpace: EditingCanvasImageProcessing.colorSpace]
      )?.cropped(to: imageBounds)
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
      .cropped(to: imageBounds)

    renderDrawableImage(
      compositedImage,
      drawable: drawable,
      descriptor: descriptor,
      commandBuffer: commandBuffer
    )
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
    commandBuffer.present(drawable)
    commandBuffer.commit()
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
