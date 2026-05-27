import CoreImage
import BrightroomEngine
import MetalKit
import simd
import UIKit

struct EditingCanvasBrushUniforms {
  var canvasSize: SIMD2<Float>
  var center: SIMD2<Float>
  var radius: Float
  var hardness: Float
  var opacity: Float
  var _padding: Float = 0
}

struct EditingCanvasLiveOverlayUniforms {
  var viewportOrigin: SIMD2<Float>
  var viewportSize: SIMD2<Float>
  var drawableSize: SIMD2<Float>
}

struct EditingCanvasVisibleImageTextureKey: Equatable {
  var visibleContentRect: CGRect
  var pixelWidth: Int
  var pixelHeight: Int
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

  private typealias BrushUniforms = EditingCanvasBrushUniforms
  private static let maximumLiveTextureDimension = 8192
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

  private let canvasSize: CGSize
  private let commandQueue: MTLCommandQueue
  private let brushPipeline: MTLRenderPipelineState
  private let liveOverlayPipeline: MTLRenderPipelineState
  private var liveStrokeTexture: MTLTexture?
  private var renderImages: EditingCanvasRenderImages?
  private var committedStrokes: [EditingCanvasStrokeRecord] = []
  private var visibleAdjustedImageTexture: MTLTexture?
  private var visibleAdjustedImageTextureKey: EditingCanvasVisibleImageTextureKey?
  private var viewportSourceTexture: EditingCanvasViewportSourceTexture?
  private var viewportCoreImageBaseLayerCache: EditingCanvasViewportCoreImageBaseLayerCache?
  private var viewportCoreImageLocalLayerCache: EditingCanvasViewportCoreImageLocalLayerCache?
  private var viewportRenderTextures: EditingCanvasViewportRenderTextures?
  private var usesViewportImageRendering = false
  private var usesViewportCachedSourceRendering = false
  private var brush = EditingCanvasBrush(
    size: 56,
    hardness: 0.72,
    opacity: 0.9,
    spacing: 0.18
  )
  private var smoothing = EditingCanvasStrokeSmoothingConfiguration(
    algorithm: .bezier,
    strength: 0.85
  )
  private var visibleContentRect: CGRect
  private var visibleCanvasFrame: CGRect = .zero
  private var strokeSmoother = EditingCanvasStrokeSmoother()
  private var lastStampPoint: CGPoint?
  private var activeStrokeStamps: [CGPoint] = []
  private var pendingLiveStamps: [CGPoint] = []
  private var liveDisplayLink: CADisplayLink?
  private var liveOverlayGeneration = 0
  private var lastLiveMetricsPublishTime: CFTimeInterval = 0
  private let liveMetricsPublishInterval: CFTimeInterval = 1.0 / 12.0
  private var drawSampleStartTime: CFTimeInterval = CACurrentMediaTime()
  private var drawSampleCount = 0
  private var measuredFramesPerSecond: Double = 0
  private let drawSampleIdleResetInterval: CFTimeInterval = 1.0
  private var displayColorConfiguration: MetalDisplayColorConfiguration {
    MetalDisplayColorManagement.configuration(
      for: traitCollection,
      prefersWideColorPixelFormat: false,
      allowsExtendedDynamicRangeContent: false
    )
  }
  private var previewOutputColorSpace: CGColorSpace {
    displayColorConfiguration.outputColorSpace
  }
  private var maskColorSpace: CGColorSpace {
    MetalDisplayColorManagement.sRGB
  }

  var activeStampCount: Int {
    activeStrokeStamps.count
  }
  var committedStampCount: Int {
    committedStrokes.reduce(0) { $0 + $1.stamps.count }
  }
  var strokeCount: Int {
    committedStrokes.count
  }
  var framesPerSecond: Double {
    measuredFramesPerSecond
  }
  var onMetricsChange: (() -> Void)?
  var onStrokeCommit: ((EditingCanvasStrokeRecord, @escaping () -> Void) -> Void)?

  var sharedDevice: MTLDevice? { device }
  var sharedBrushPipeline: MTLRenderPipelineState { brushPipeline }
  var hasRenderImages: Bool { renderImages != nil }

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
    self.visibleContentRect = CGRect(origin: .zero, size: canvasSize)

    do {
      let library = try Self.makeShaderLibrary(device: device)
      self.brushPipeline = try Self.makeBrushPipeline(device: device, library: library)
      self.liveOverlayPipeline = try Self.makeLiveOverlayPipeline(device: device, library: library)
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
    accessibilityLabel = "Metal Brush Canvas"
    isHidden = true
    applyDisplayColorConfiguration(invalidatesCaches: false)
    if #available(iOS 17, *) {
      registerForTraitChanges([UITraitDisplayGamut.self]) { (view: _EditingCanvasMTKView, _) in
        view.applyDisplayColorConfiguration(invalidatesCaches: true)
      }
    }
    if let metalLayer = layer as? CAMetalLayer {
      metalLayer.maximumDrawableCount = 3
    }

    makeLayerTextures()
    reset()
  }

  @available(*, unavailable)
  required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func applyDisplayColorConfiguration(invalidatesCaches: Bool) {
    MetalDisplayColorManagement.apply(
      displayColorConfiguration,
      to: self
    )

    guard invalidatesCaches else {
      return
    }

    visibleAdjustedImageTextureKey = nil
    viewportSourceTexture = nil
    viewportRenderTextures = nil
    invalidateViewportCoreImageLayerCaches()
    setNeedsDisplay()
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
    self.brush = brush

    if self.smoothing != smoothing {
      self.smoothing = smoothing
      strokeSmoother.configure(smoothing)
      cancelActiveStroke()
      lastStampPoint = nil
    }

    if isHidden == false {
      setNeedsDisplay()
    }
  }

  func setRenderImages(_ images: EditingCanvasRenderImages) {
    renderImages = images
    visibleAdjustedImageTextureKey = nil
    viewportRenderTextures = nil
    invalidateViewportCoreImageLayerCaches()
    if usesViewportImageRendering {
      visibleAdjustedImageTexture = nil
      setNeedsDisplay()
      return
    }
    updateVisibleAdjustedImageTextureIfNeeded()
    if isHidden == false {
      setNeedsDisplay()
    }
  }

  func setViewportCachedSourceEnabled(_ isEnabled: Bool) {
    guard usesViewportCachedSourceRendering != isEnabled else {
      return
    }

    usesViewportCachedSourceRendering = isEnabled
    viewportSourceTexture = nil
    viewportRenderTextures = nil
    invalidateViewportCoreImageLayerCaches()
    if usesViewportImageRendering {
      setNeedsDisplay()
    }
  }

  func setCommittedStrokes(_ records: [EditingCanvasStrokeRecord]) {
    committedStrokes = records
    viewportRenderTextures = nil
    if usesViewportImageRendering {
      setNeedsDisplay()
    }
  }

  func setViewportImageRenderingEnabled(_ isEnabled: Bool) {
    guard usesViewportImageRendering != isEnabled else {
      return
    }

    usesViewportImageRendering = isEnabled
    visibleAdjustedImageTexture = nil
    visibleAdjustedImageTextureKey = nil
    viewportSourceTexture = nil
    viewportRenderTextures = nil
    invalidateViewportCoreImageLayerCaches()

    if isEnabled {
      stopLiveDisplayLink()
      isHidden = false
      setNeedsDisplay()
    } else if activeStrokeStamps.isEmpty {
      isHidden = true
    }
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

    let didChangeViewport = visibleContentRect.equalTo(nextRect) == false
      || visibleCanvasFrame.equalTo(nextFrame) == false
    guard didChangeViewport else {
      if usesViewportImageRendering == false {
        updateVisibleAdjustedImageTextureIfNeeded()
      }
      return
    }

    visibleContentRect = nextRect
    visibleCanvasFrame = nextFrame
    visibleAdjustedImageTextureKey = nil
    viewportSourceTexture = nil
    viewportRenderTextures = nil
    invalidateViewportCoreImageLayerCaches()
    if usesViewportImageRendering {
      setNeedsDisplay()
      onMetricsChange?()
      return
    }
    updateVisibleAdjustedImageTextureIfNeeded()
    if isHidden == false {
      setNeedsDisplay()
    }
    onMetricsChange?()
  }

  func reset() {
    cancelActiveStroke()
    onMetricsChange?()
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    if activeStrokeStamps.isEmpty == false {
      cancelActiveStroke()
    }
    liveStrokeTexture = makeStrokeTexture(size: size)
    visibleAdjustedImageTextureKey = nil
    viewportRenderTextures = nil
    invalidateViewportCoreImageLayerCaches()
    if usesViewportImageRendering {
      setNeedsDisplay()
    } else {
      updateVisibleAdjustedImageTextureIfNeeded()
    }
  }

  func draw(in view: MTKView) {
    defer {
      recordDrawSample()
    }

    if usesViewportImageRendering {
      renderViewportImage()
    } else {
      renderLiveOverlay()
    }
  }

  func beginStroke(at rawPoint: CGPoint) {
    liveOverlayGeneration += 1
    isHidden = false
    activeStrokeStamps.removeAll(keepingCapacity: true)
    if usesViewportImageRendering {
      pendingLiveStamps.removeAll(keepingCapacity: true)
    } else {
      ensureLiveStrokeTextureMatchesDrawable()
      clearLiveStrokeTexture(hidesOverlay: false)
    }
    strokeSmoother.begin(at: rawPoint)
    lastStampPoint = rawPoint
    renderLiveStamps([rawPoint], flushImmediately: true)
  }

  func appendStroke(points rawPoints: [CGPoint]) {
    guard rawPoints.isEmpty == false else {
      return
    }

    let sampleDistance = max(CGFloat(brush.size * brush.spacing) * 0.5, 2)
    let smoothedPoints = strokeSmoother.append(
      rawPoints,
      sampleDistance: sampleDistance
    )
    let stamps = smoothedPoints.flatMap { point -> [CGPoint] in
      stampPoints(to: point)
    }

    renderLiveStamps(stamps)
  }

  func endStroke(at rawPoint: CGPoint) {
    let sampleDistance = max(CGFloat(brush.size * brush.spacing) * 0.5, 2)
    let smoothedPoints = strokeSmoother.finish(
      at: rawPoint,
      sampleDistance: sampleDistance
    )
    let stamps = smoothedPoints.flatMap { point -> [CGPoint] in
      stampPoints(to: point)
    }

    renderLiveStamps(stamps, flushImmediately: true)
    commitActiveStroke()
    strokeSmoother.reset()
    lastStampPoint = nil
  }

  func cancelStroke() {
    cancelActiveStroke()
  }

  private func makeLayerTextures() {
    liveStrokeTexture = nil
  }

  private func makeStrokeTexture(size: CGSize) -> MTLTexture? {
    guard let device else {
      return nil
    }

    let width = max(Int(size.width.rounded(.up)), 1)
    let height = max(Int(size.height.rounded(.up)), 1)
    guard width <= Self.maximumLiveTextureDimension,
          height <= Self.maximumLiveTextureDimension
    else {
      return nil
    }

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm,
      width: width,
      height: height,
      mipmapped: false
    )
    descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
    descriptor.storageMode = .private
    return device.makeTexture(descriptor: descriptor)
  }

  private func makeLiveStrokeTextureForCurrentDrawable() -> MTLTexture? {
    let size = drawableSize
    let fallback = CGSize(
      width: max(bounds.width, 1) * contentScaleFactor,
      height: max(bounds.height, 1) * contentScaleFactor
    )
    let target = size.width > 0 && size.height > 0 ? size : fallback
    return makeStrokeTexture(size: target)
  }

  private func updateVisibleAdjustedImageTextureIfNeeded() {
    guard
      let renderImages,
      renderImages.hasLocalEffect,
      let device,
      visibleContentRect.width > 0,
      visibleContentRect.height > 0,
      visibleCanvasFrame.width > 0,
      visibleCanvasFrame.height > 0,
      bounds.width > 0,
      bounds.height > 0
    else {
      visibleAdjustedImageTexture = nil
      visibleAdjustedImageTextureKey = nil
      return
    }
    let adjustedImage = renderImages.adjusted

    let drawableScaleX = drawableSize.width / bounds.width
    let drawableScaleY = drawableSize.height / bounds.height
    let pixelWidth = min(
      Self.maximumLiveTextureDimension,
      alignedPixelSize(visibleCanvasFrame.width * drawableScaleX)
    )
    let pixelHeight = min(
      Self.maximumLiveTextureDimension,
      alignedPixelSize(visibleCanvasFrame.height * drawableScaleY)
    )
    guard pixelWidth > 0, pixelHeight > 0 else {
      visibleAdjustedImageTexture = nil
      visibleAdjustedImageTextureKey = nil
      return
    }

    let key = EditingCanvasVisibleImageTextureKey(
      visibleContentRect: visibleContentRect,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight
    )
    guard visibleAdjustedImageTextureKey != key else {
      return
    }

    let texture: MTLTexture
    if let existingTexture = visibleAdjustedImageTexture,
       existingTexture.width == pixelWidth,
       existingTexture.height == pixelHeight
    {
      texture = existingTexture
    } else {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm,
        width: pixelWidth,
        height: pixelHeight,
        mipmapped: false
      )
      descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
      descriptor.storageMode = .private
      guard let newTexture = device.makeTexture(descriptor: descriptor) else {
        return
      }
      texture = newTexture
    }

    guard
      let commandBuffer = commandQueue.makeCommandBuffer()
    else {
      return
    }

    render(
      adjustedImage,
      canvasRect: visibleContentRect,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      into: texture,
      commandBuffer: commandBuffer
    )
    commandBuffer.commit()

    visibleAdjustedImageTexture = texture
    visibleAdjustedImageTextureKey = key
  }

  private func render(
    _ image: CIImage,
    canvasRect: CGRect,
    pixelWidth: Int,
    pixelHeight: Int,
    into texture: MTLTexture,
    commandBuffer: MTLCommandBuffer
  ) {
    let renderBounds = CGRect(
      x: 0,
      y: 0,
      width: pixelWidth,
      height: pixelHeight
    )
    let scaleX = CGFloat(pixelWidth) / canvasRect.width
    let scaleY = CGFloat(pixelHeight) / canvasRect.height
    let visibleImage = image
      .transformed(
        by: CGAffineTransform(
          translationX: -canvasRect.minX,
          y: -canvasRect.minY
        )
      )
      .transformed(
        by: CGAffineTransform(
          scaleX: scaleX,
          y: scaleY
        )
      )
      .cropped(to: renderBounds)

    ciContext.render(
      visibleImage,
      to: texture,
      commandBuffer: commandBuffer,
      bounds: renderBounds,
      colorSpace: previewOutputColorSpace
    )
  }

  private func alignedPixelSize(_ value: CGFloat) -> Int {
    let raw = max(Int(value.rounded()), 4)
    return (raw + 3) & ~3
  }

  private func recordDrawSample(now: CFTimeInterval = CACurrentMediaTime()) {
    if drawSampleCount == 0, now - drawSampleStartTime > drawSampleIdleResetInterval {
      drawSampleStartTime = now
    }

    drawSampleCount += 1
    let elapsed = now - drawSampleStartTime
    guard elapsed >= 0.5 else {
      return
    }

    measuredFramesPerSecond = Double(drawSampleCount) / elapsed
    drawSampleCount = 0
    drawSampleStartTime = now
    onMetricsChange?()
  }

  private func ensureLiveStrokeTextureMatchesDrawable() {
    let target = drawableSize
    guard target.width > 0, target.height > 0 else {
      return
    }
    let current = liveStrokeTexture
    if let current,
       current.width == Int(target.width.rounded(.up)),
       current.height == Int(target.height.rounded(.up))
    {
      return
    }
    liveStrokeTexture = makeStrokeTexture(size: target)
  }

  private func clearLiveStrokeTexture(hidesOverlay: Bool = true) {
    if hidesOverlay {
      isHidden = usesViewportImageRendering == false
    }
    clearTexture(liveStrokeTexture)
    setNeedsDisplay()
  }

  private func clearTexture(_ texture: MTLTexture?) {
    guard
      let texture,
      let commandBuffer = commandQueue.makeCommandBuffer()
    else {
      return
    }

    encodeClearTexture(texture, commandBuffer: commandBuffer)
    commandBuffer.commit()
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
    liveOverlayGeneration += 1
    strokeSmoother.reset()
    activeStrokeStamps.removeAll(keepingCapacity: true)
    pendingLiveStamps.removeAll(keepingCapacity: true)
    stopLiveDisplayLink()
    clearLiveStrokeTexture()
    lastStampPoint = nil
  }

  private func stampPoints(to point: CGPoint) -> [CGPoint] {
    guard let lastStampPoint else {
      self.lastStampPoint = point
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

    self.lastStampPoint = newestStampPoint
    return stamps
  }

  private func renderLiveStamps(_ stamps: [CGPoint], flushImmediately: Bool = false) {
    guard stamps.isEmpty == false else {
      return
    }

    activeStrokeStamps += stamps
    pendingLiveStamps += stamps
    isHidden = false
    if usesViewportImageRendering {
      startLiveDisplayLinkIfNeeded()
      if flushImmediately {
        pendingLiveStamps.removeAll(keepingCapacity: true)
        setNeedsDisplay()
        publishLiveMetricsIfNeeded(force: true)
      } else {
        publishLiveMetricsIfNeeded()
      }
      return
    }

    startLiveDisplayLinkIfNeeded()

    if flushImmediately {
      flushPendingLiveStamps()
      publishLiveMetricsIfNeeded(force: true)
    } else {
      publishLiveMetricsIfNeeded()
    }
  }

  private func commitActiveStroke() {
    guard activeStrokeStamps.isEmpty == false else {
      clearLiveStrokeTexture()
      return
    }

    flushPendingLiveStamps()
    stopLiveDisplayLink()

    let stamps = activeStrokeStamps
    activeStrokeStamps.removeAll(keepingCapacity: true)
    let generation = liveOverlayGeneration

    let record = EditingCanvasStrokeRecord(stamps: stamps, brush: brush)
    let clearLiveOverlay = { [weak self] in
      guard let self else { return }
      self.finishCommittedStrokeOverlay(for: generation)
    }

    if let onStrokeCommit {
      onStrokeCommit(record, clearLiveOverlay)
    } else {
      clearLiveOverlay()
    }
  }

  private func finishCommittedStrokeOverlay(for generation: Int) {
    if Thread.isMainThread == false {
      DispatchQueue.main.async { [weak self] in
        self?.finishCommittedStrokeOverlay(for: generation)
      }
      return
    }

    guard liveOverlayGeneration == generation, activeStrokeStamps.isEmpty else {
      return
    }

    isHidden = usesViewportImageRendering == false
    onMetricsChange?()

    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      guard self.liveOverlayGeneration == generation, self.activeStrokeStamps.isEmpty else {
        return
      }
      self.clearTexture(self.liveStrokeTexture)
    }
  }

  private func renderStamps(
    _ stamps: [CGPoint],
    into texture: MTLTexture?
  ) {
    guard
      stamps.isEmpty == false,
      let texture,
      let commandBuffer = commandQueue.makeCommandBuffer()
    else {
      return
    }

    encodeLiveStamps(stamps, into: texture, commandBuffer: commandBuffer)
    commandBuffer.commit()
    setNeedsDisplay()
  }

  private func startLiveDisplayLinkIfNeeded() {
    guard liveDisplayLink == nil else { return }

    let displayLink = CADisplayLink(
      target: self,
      selector: #selector(liveDisplayLinkDidTick(_:))
    )
    displayLink.preferredFrameRateRange = LiveFrameRate.range(for: window?.screen)
    displayLink.add(to: .main, forMode: .common)
    liveDisplayLink = displayLink
  }

  private func updatePreferredFrameRate() {
    preferredFramesPerSecond = LiveFrameRate.targetMaximum(for: window?.screen)
    liveDisplayLink?.preferredFrameRateRange = LiveFrameRate.range(for: window?.screen)
  }

  private func stopLiveDisplayLink() {
    liveDisplayLink?.invalidate()
    liveDisplayLink = nil
  }

  @objc private func liveDisplayLinkDidTick(_ displayLink: CADisplayLink) {
    if usesViewportImageRendering {
      if pendingLiveStamps.isEmpty == false {
        pendingLiveStamps.removeAll(keepingCapacity: true)
        setNeedsDisplay()
      }
      publishLiveMetricsIfNeeded(now: displayLink.timestamp)
      return
    }

    flushPendingLiveStamps()
    publishLiveMetricsIfNeeded(now: displayLink.timestamp)
  }

  private func flushPendingLiveStamps() {
    guard pendingLiveStamps.isEmpty == false else {
      return
    }

    let stamps = pendingLiveStamps
    pendingLiveStamps.removeAll(keepingCapacity: true)
    renderStamps(stamps, into: liveStrokeTexture)
  }

  private func publishLiveMetricsIfNeeded(
    force: Bool = false,
    now: CFTimeInterval = CACurrentMediaTime()
  ) {
    guard force || now - lastLiveMetricsPublishTime >= liveMetricsPublishInterval else {
      return
    }

    lastLiveMetricsPublishTime = now
    onMetricsChange?()
  }

  private func encodeLiveStamps(
    _ canvasStamps: [CGPoint],
    into texture: MTLTexture,
    commandBuffer: MTLCommandBuffer
  ) {
    let visible = visibleContentRect
    let viewportFrame = visibleCanvasFrame
    let target = drawableSize
    guard
      canvasStamps.isEmpty == false,
      visible.width > 0, visible.height > 0,
      viewportFrame.width > 0, viewportFrame.height > 0,
      bounds.width > 0, bounds.height > 0,
      target.width > 0, target.height > 0
    else {
      return
    }

    let drawableScaleX = target.width / bounds.width
    let drawableScaleY = target.height / bounds.height
    let contentToViewScaleX = viewportFrame.width / visible.width
    let contentToViewScaleY = viewportFrame.height / visible.height
    let pixelScaleX = contentToViewScaleX * drawableScaleX
    let pixelScaleY = contentToViewScaleY * drawableScaleY
    let brushPixelScale = (pixelScaleX + pixelScaleY) * 0.5
    let targetSize = SIMD2(Float(target.width), Float(target.height))
    let hardness = Float(brush.hardness)
    let opacity = Float(brush.opacity)
    let pixelRadius = Float(brush.size / 2 * Double(brushPixelScale))

    let descriptor = MTLRenderPassDescriptor()
    descriptor.colorAttachments[0].texture = texture
    descriptor.colorAttachments[0].loadAction = .load
    descriptor.colorAttachments[0].storeAction = .store

    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
      return
    }

    encoder.setRenderPipelineState(brushPipeline)

    for stamp in canvasStamps {
      var uniforms = BrushUniforms(
        canvasSize: targetSize,
        center: SIMD2(
          Float((viewportFrame.minX + (stamp.x - visible.minX) * contentToViewScaleX) * drawableScaleX),
          Float((viewportFrame.minY + (stamp.y - visible.minY) * contentToViewScaleY) * drawableScaleY)
        ),
        radius: pixelRadius,
        hardness: hardness,
        opacity: opacity
      )

      encoder.setVertexBytes(&uniforms, length: MemoryLayout<BrushUniforms>.stride, index: 0)
      encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BrushUniforms>.stride, index: 0)
      encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    encoder.endEncoding()
  }

  private func renderLiveOverlay() {
    guard
      let liveStrokeTexture,
      let visibleAdjustedImageTexture,
      let drawable = currentDrawable,
      let descriptor = currentRenderPassDescriptor,
      let commandBuffer = commandQueue.makeCommandBuffer()
    else {
      return
    }

    descriptor.colorAttachments[0].loadAction = .clear
    descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    descriptor.colorAttachments[0].storeAction = .store

    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
      return
    }

    encoder.setRenderPipelineState(liveOverlayPipeline)
    encoder.setFragmentTexture(liveStrokeTexture, index: 0)
    encoder.setFragmentTexture(visibleAdjustedImageTexture, index: 1)
    let drawableScaleX = drawableSize.width / max(bounds.width, 1)
    let drawableScaleY = drawableSize.height / max(bounds.height, 1)
    var overlayUniforms = EditingCanvasLiveOverlayUniforms(
      viewportOrigin: CGPoint(
        x: visibleCanvasFrame.minX * drawableScaleX,
        y: visibleCanvasFrame.minY * drawableScaleY
      ).simdFloat2,
      viewportSize: CGSize(
        width: visibleCanvasFrame.width * drawableScaleX,
        height: visibleCanvasFrame.height * drawableScaleY
      ).simdFloat2,
      drawableSize: drawableSize.simdFloat2
    )
    encoder.setFragmentBytes(
      &overlayUniforms,
      length: MemoryLayout<EditingCanvasLiveOverlayUniforms>.stride,
      index: 0
    )
    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

    encoder.endEncoding()
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }

  private func renderViewportImage() {
    guard
      let renderImages,
      let drawable = currentDrawable,
      let descriptor = currentRenderPassDescriptor,
      let commandBuffer = commandQueue.makeCommandBuffer(),
      bounds.width > 0,
      bounds.height > 0,
      visibleContentRect.width > 0,
      visibleContentRect.height > 0,
      visibleCanvasFrame.width > 0,
      visibleCanvasFrame.height > 0
    else {
      clearCurrentDrawable()
      return
    }

    guard usesViewportCachedSourceRendering == false || renderImages.usesPreparedBaseImage else {
      renderViewportCachedSource(
        renderImages,
        drawable: drawable,
        descriptor: descriptor,
        commandBuffer: commandBuffer
      )
      return
    }

    guard renderImages.hasLocalEffect,
          hasRenderableStroke(in: visibleContentRect)
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
    let scaleX = destinationFrame.width / visibleContentRect.width
    let scaleY = destinationFrame.height / visibleContentRect.height
    let visibleImage = image
      .transformed(
        by: CGAffineTransform(
          translationX: -visibleContentRect.minX,
          y: -visibleContentRect.minY
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
      colorSpace: previewOutputColorSpace
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
          hasRenderableStroke(in: visibleContentRect)
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
      visibleContentRect.width > 0,
      visibleContentRect.height > 0,
      visibleCanvasFrame.width > 0,
      visibleCanvasFrame.height > 0
    else {
      return 1
    }

    let drawableScaleX = CGFloat(pixelWidth) / bounds.width
    let drawableScaleY = CGFloat(pixelHeight) / bounds.height
    let pixelScaleX = visibleCanvasFrame.width * drawableScaleX / visibleContentRect.width
    let pixelScaleY = visibleCanvasFrame.height * drawableScaleY / visibleContentRect.height
    return max((pixelScaleX + pixelScaleY) * 0.5, 0.0001)
  }

  private func invalidateViewportCoreImageLayerCaches() {
    viewportCoreImageBaseLayerCache = nil
    viewportCoreImageLocalLayerCache = nil
  }

  private func viewportSourceImage(
    _ source: CIImage,
    pixelWidth: Int,
    pixelHeight: Int
  ) -> CIImage? {
    let key = EditingCanvasViewportSourceTextureKey(
      sourceExtent: source.extent,
      visibleContentRect: visibleContentRect,
      visibleCanvasFrame: visibleCanvasFrame,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight
    )
    if let cachedSource = viewportSourceTexture, cachedSource.key == key {
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
      options: [.colorSpace: previewOutputColorSpace]
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
    viewportSourceTexture = cachedSource
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
      colorSpace: previewOutputColorSpace
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
      visibleContentRect: visibleContentRect,
      visibleCanvasFrame: visibleCanvasFrame,
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
      options: [.colorSpace: maskColorSpace]
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
    if let cache = viewportCoreImageBaseLayerCache, cache.key == key {
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

    viewportCoreImageBaseLayerCache = EditingCanvasViewportCoreImageBaseLayerCache(
      key: key,
      texture: texture,
      image: cachedImage
    )
    viewportCoreImageLocalLayerCache = nil
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
    if let cache = viewportCoreImageLocalLayerCache, cache.key == key {
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

    viewportCoreImageLocalLayerCache = EditingCanvasViewportCoreImageLocalLayerCache(
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
      options: [.colorSpace: previewOutputColorSpace]
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
      colorSpace: previewOutputColorSpace
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
        options: [.colorSpace: previewOutputColorSpace]
      )?.cropped(to: imageBounds),
      let adjustedImage = CIImage(
        mtlTexture: adjustedTexture,
        options: [.colorSpace: previewOutputColorSpace]
      )?.cropped(to: imageBounds),
      let maskImage = CIImage(
        mtlTexture: textures.maskTexture,
        options: [.colorSpace: maskColorSpace]
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
    let scaleX = destinationFrame.width / visibleContentRect.width
    let scaleY = destinationFrame.height / visibleContentRect.height
    let visibleImage = image
      .transformed(
        by: CGAffineTransform(
          translationX: -visibleContentRect.minX,
          y: -visibleContentRect.minY
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
      colorSpace: previewOutputColorSpace
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
      x: visibleCanvasFrame.minX * drawableScaleX,
      y: visibleCanvasFrame.minY * drawableScaleY,
      width: visibleCanvasFrame.width * drawableScaleX,
      height: visibleCanvasFrame.height * drawableScaleY
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
    if let textures = viewportRenderTextures,
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
    viewportRenderTextures = textures
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
    let visible = visibleContentRect
    let viewportFrame = visibleCanvasFrame
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

    encoder.setRenderPipelineState(brushPipeline)

    func encode(stamps: [CGPoint], brush: EditingCanvasBrush) {
      let radius = CGFloat(brush.size / 2)
      let pixelRadius = Float(Double(radius) * Double((pixelScaleX + pixelScaleY) * 0.5))
      let hardness = Float(brush.hardness)
      let opacity = Float(brush.opacity)

      for stamp in stamps where stampIntersectsVisibleRect(stamp, radius: radius, visible: visible) {
        var uniforms = BrushUniforms(
          canvasSize: targetSize,
          center: SIMD2(
            Float((viewportFrame.minX + (stamp.x - visible.minX) * contentToViewScaleX) * drawableScaleX),
            Float((viewportFrame.minY + (stamp.y - visible.minY) * contentToViewScaleY) * drawableScaleY)
          ),
          radius: pixelRadius,
          hardness: hardness,
          opacity: opacity
        )
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<BrushUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BrushUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
      }
    }

    for stroke in committedStrokes where stroke.bounds.intersects(visible) {
      encode(stamps: stroke.stamps, brush: stroke.brush)
    }

    if activeStrokeStamps.isEmpty == false {
      encode(stamps: activeStrokeStamps, brush: brush)
    }

    encoder.endEncoding()
  }

  private func hasRenderableStroke(in canvasRect: CGRect) -> Bool {
    if activeStrokeStamps.contains(where: {
      stampIntersectsVisibleRect(
        $0,
        radius: CGFloat(brush.size / 2),
        visible: canvasRect
      )
    }) {
      return true
    }

    return committedStrokes.contains { stroke in
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

  private static func makeBrushPipeline(
    device: MTLDevice,
    library: MTLLibrary
  ) throws -> MTLRenderPipelineState {
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "brushVertex")
    descriptor.fragmentFunction = library.makeFunction(name: "brushFragment")
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

  private static func makeLiveOverlayPipeline(
    device: MTLDevice,
    library: MTLLibrary
  ) throws -> MTLRenderPipelineState {
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "displayVertex")
    descriptor.fragmentFunction = library.makeFunction(name: "liveOverlayFragment")
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    return try device.makeRenderPipelineState(descriptor: descriptor)
  }

  private static func makeShaderLibrary(device: MTLDevice) throws -> MTLLibrary {
    try device.makeLibrary(source: EditingCanvasShaderSource.source, options: nil)
  }
}
