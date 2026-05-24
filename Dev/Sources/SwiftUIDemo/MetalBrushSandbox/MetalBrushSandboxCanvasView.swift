import CoreImage
import BrightroomEngine
import IOSurface
import MetalKit
import os
import simd
import SwiftUI
import UIKit

struct MetalBrushUniforms {
  var canvasSize: SIMD2<Float>
  var center: SIMD2<Float>
  var radius: Float
  var hardness: Float
  var opacity: Float
  var _padding: Float = 0
}

struct MetalBrushLiveOverlayUniforms {
  var viewportOrigin: SIMD2<Float>
  var viewportSize: SIMD2<Float>
  var drawableSize: SIMD2<Float>
}

struct MetalBrushVisibleImageTextureKey: Equatable {
  var visibleContentRect: CGRect
  var pixelWidth: Int
  var pixelHeight: Int
}

private struct MetalBrushViewportSourceTextureKey: Equatable {
  var sourceExtent: CGRect
  var visibleContentRect: CGRect
  var visibleCanvasFrame: CGRect
  var pixelWidth: Int
  var pixelHeight: Int
}

private struct MetalBrushViewportSourceTexture {
  let key: MetalBrushViewportSourceTextureKey
  let texture: MTLTexture
  let image: CIImage
}

private struct MetalBrushViewportRenderTextures {
  let pixelWidth: Int
  let pixelHeight: Int
  let baseTexture: MTLTexture
  let blurredTexture: MTLTexture
  let maskTexture: MTLTexture
}

final class MetalBrushSandboxCanvasView: MTKView, MTKViewDelegate {

  private typealias BrushUniforms = MetalBrushUniforms
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
  private let tileCompositePipeline: MTLRenderPipelineState
  private var liveStrokeTexture: MTLTexture?
  private var renderImages: MetalBrushSandboxRenderImages?
  private var committedStrokes: [MetalBrushSandboxStrokeRecord] = []
  private var visibleBlurredImageTexture: MTLTexture?
  private var visibleBlurredImageTextureKey: MetalBrushVisibleImageTextureKey?
  private var viewportSourceTexture: MetalBrushViewportSourceTexture?
  private var viewportRenderTextures: MetalBrushViewportRenderTextures?
  private var usesViewportImageRendering = false
  private var usesViewportCachedSourceRendering = false
  private var brush = MetalBrushSandboxBrush(
    size: 56,
    hardness: 0.72,
    opacity: 0.9,
    spacing: 0.18
  )
  private var smoothing = MetalBrushStrokeSmoothingConfiguration(
    algorithm: .bezier,
    strength: 0.85
  )
  private var visibleContentRect: CGRect
  private var visibleCanvasFrame: CGRect = .zero
  private var strokeSmoother = MetalBrushStrokeSmoother()
  private var lastStampPoint: CGPoint?
  private var activeStrokeStamps: [CGPoint] = []
  private var pendingLiveStamps: [CGPoint] = []
  private var liveDisplayLink: CADisplayLink?
  private var liveOverlayGeneration = 0
  private var lastLiveMetricsPublishTime: CFTimeInterval = 0
  private let liveMetricsPublishInterval: CFTimeInterval = 1.0 / 12.0
  var stampCount: Int {
    activeStrokeStamps.count
  }
  var onMetricsChange: (() -> Void)?
  var onStrokeCommit: ((MetalBrushSandboxStrokeRecord, @escaping () -> Void) -> Void)?

  var sharedDevice: MTLDevice? { device }
  var sharedBrushPipeline: MTLRenderPipelineState { brushPipeline }
  var sharedTileCompositePipeline: MTLRenderPipelineState { tileCompositePipeline }
  var hasRenderImages: Bool { renderImages != nil }

  private lazy var ciContext: CIContext = {
    [unowned self] in
    CIContext(mtlDevice: self.device!)
  }()

  init(canvasSize: CGSize, device: MTLDevice) {
    self.canvasSize = canvasSize
    self.commandQueue = device.makeCommandQueue()!
    self.visibleContentRect = CGRect(origin: .zero, size: canvasSize)

    do {
      let library = try Self.makeShaderLibrary(device: device)
      self.brushPipeline = try Self.makeBrushPipeline(device: device, library: library)
      self.liveOverlayPipeline = try Self.makeLiveOverlayPipeline(device: device, library: library)
      self.tileCompositePipeline = try Self.makeTileCompositePipeline(device: device, library: library)
    } catch {
      fatalError("Failed to create Metal Brush Sandbox pipeline: \(error)")
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
    accessibilityIdentifier = "metal-brush-sandbox-metal-view"
    isAccessibilityElement = true
    accessibilityLabel = "Metal Brush Canvas"
    isHidden = true
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

  deinit {
    stopLiveDisplayLink()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    updatePreferredFrameRate()
  }

  func configure(
    brush: MetalBrushSandboxBrush,
    smoothing: MetalBrushStrokeSmoothingConfiguration
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

  func setRenderImages(_ images: MetalBrushSandboxRenderImages) {
    renderImages = images
    visibleBlurredImageTextureKey = nil
    viewportRenderTextures = nil
    if usesViewportImageRendering {
      visibleBlurredImageTexture = nil
      setNeedsDisplay()
      return
    }
    updateVisibleBlurredImageTextureIfNeeded()
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
    if usesViewportImageRendering {
      setNeedsDisplay()
    }
  }

  func setCommittedStrokes(_ records: [MetalBrushSandboxStrokeRecord]) {
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
    visibleBlurredImageTexture = nil
    visibleBlurredImageTextureKey = nil
    viewportSourceTexture = nil
    viewportRenderTextures = nil

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
      if usesViewportImageRendering {
        setNeedsDisplay()
      } else {
        updateVisibleBlurredImageTextureIfNeeded()
      }
      return
    }

    visibleContentRect = nextRect
    visibleCanvasFrame = nextFrame
    visibleBlurredImageTextureKey = nil
    viewportSourceTexture = nil
    viewportRenderTextures = nil
    if usesViewportImageRendering {
      setNeedsDisplay()
      onMetricsChange?()
      return
    }
    updateVisibleBlurredImageTextureIfNeeded()
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
    visibleBlurredImageTextureKey = nil
    viewportRenderTextures = nil
    if usesViewportImageRendering {
      setNeedsDisplay()
    } else {
      updateVisibleBlurredImageTextureIfNeeded()
    }
  }

  func draw(in view: MTKView) {
    if usesViewportImageRendering {
      renderViewportImage()
    } else {
      renderLiveOverlay()
    }
  }

  func beginStroke(at rawPoint: CGPoint) {
    guard usesViewportImageRendering == false else {
      return
    }
    ensureLiveStrokeTextureMatchesDrawable()
    liveOverlayGeneration += 1
    isHidden = false
    activeStrokeStamps.removeAll(keepingCapacity: true)
    clearLiveStrokeTexture(hidesOverlay: false)
    let point = clampedContentPoint(rawPoint)
    strokeSmoother.begin(at: point)
    lastStampPoint = point
    renderLiveStamps([point], flushImmediately: true)
  }

  func appendStroke(points rawPoints: [CGPoint]) {
    guard rawPoints.isEmpty == false else {
      return
    }

    let sampleDistance = max(CGFloat(brush.size * brush.spacing) * 0.5, 2)
    let inputPoints = rawPoints.map { clampedContentPoint($0) }
    let smoothedPoints = strokeSmoother.append(
      inputPoints,
      sampleDistance: sampleDistance
    )
    let stamps = smoothedPoints.flatMap { point -> [CGPoint] in
      stampPoints(to: point)
    }

    renderLiveStamps(stamps)
  }

  func endStroke(at rawPoint: CGPoint) {
    let sampleDistance = max(CGFloat(brush.size * brush.spacing) * 0.5, 2)
    let point = clampedContentPoint(rawPoint)
    let smoothedPoints = strokeSmoother.finish(
      at: point,
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

  private func updateVisibleBlurredImageTextureIfNeeded() {
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
      visibleBlurredImageTexture = nil
      visibleBlurredImageTextureKey = nil
      return
    }
    let blurredImage = renderImages.blurred

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
      visibleBlurredImageTexture = nil
      visibleBlurredImageTextureKey = nil
      return
    }

    let key = MetalBrushVisibleImageTextureKey(
      visibleContentRect: visibleContentRect,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight
    )
    guard visibleBlurredImageTextureKey != key else {
      return
    }

    let texture: MTLTexture
    if let existingTexture = visibleBlurredImageTexture,
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
      blurredImage,
      canvasRect: visibleContentRect,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      into: texture,
      commandBuffer: commandBuffer
    )
    commandBuffer.commit()

    visibleBlurredImageTexture = texture
    visibleBlurredImageTextureKey = key
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
      colorSpace: MetalBrushSandboxImageProcessing.colorSpace
    )
  }

  private func alignedPixelSize(_ value: CGFloat) -> Int {
    let raw = max(Int(value.rounded()), 4)
    return (raw + 3) & ~3
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

    let record = MetalBrushSandboxStrokeRecord(stamps: stamps, brush: brush)
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
      let visibleBlurredImageTexture,
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
    encoder.setFragmentTexture(visibleBlurredImageTexture, index: 1)
    let drawableScaleX = drawableSize.width / max(bounds.width, 1)
    let drawableScaleY = drawableSize.height / max(bounds.height, 1)
    var overlayUniforms = MetalBrushLiveOverlayUniforms(
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
      length: MemoryLayout<MetalBrushLiveOverlayUniforms>.stride,
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

    guard usesViewportCachedSourceRendering == false else {
      renderViewportCachedSource(
        renderImages,
        drawable: drawable,
        descriptor: descriptor,
        commandBuffer: commandBuffer
      )
      return
    }

    guard renderImages.hasLocalEffect,
          hasRenderableCommittedStroke(in: visibleContentRect)
    else {
      renderViewportBaseImage(
        renderImages.base,
        drawable: drawable,
        descriptor: descriptor,
        commandBuffer: commandBuffer
      )
      return
    }

    renderViewportComposite(
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
    let drawableScaleX = CGFloat(drawable.texture.width) / bounds.width
    let drawableScaleY = CGFloat(drawable.texture.height) / bounds.height
    let destinationFrame = CGRect(
      x: visibleCanvasFrame.minX * drawableScaleX,
      y: visibleCanvasFrame.minY * drawableScaleY,
      width: visibleCanvasFrame.width * drawableScaleX,
      height: visibleCanvasFrame.height * drawableScaleY
    )
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
      colorSpace: MetalBrushSandboxImageProcessing.colorSpace
    )
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }

  private func renderViewportCachedSource(
    _ renderImages: MetalBrushSandboxRenderImages,
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

    let baseImage = renderImages.filters
      .apply(to: sourceImage)
      .cropped(to: sourceImage.extent)

    guard renderImages.hasLocalEffect,
          hasRenderableCommittedStroke(in: visibleContentRect)
    else {
      renderDrawableImage(
        baseImage,
        drawable: drawable,
        descriptor: descriptor,
        commandBuffer: commandBuffer
      )
      return
    }

    let blurredImage = baseImage
      .clamped(to: sourceImage.extent)
      .applyingFilter(
        "CIGaussianBlur",
        parameters: [
          kCIInputRadiusKey: scaledViewportBlurRadius(
            renderImages.blurRadius,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
          )
        ]
      )
      .cropped(to: sourceImage.extent)

    renderViewportCachedComposite(
      baseImage: baseImage,
      blurredImage: blurredImage,
      drawable: drawable,
      descriptor: descriptor,
      commandBuffer: commandBuffer
    )
  }

  private func scaledViewportBlurRadius(
    _ canvasRadius: Double,
    pixelWidth: Int,
    pixelHeight: Int
  ) -> Double {
    guard
      canvasRadius > 0,
      bounds.width > 0,
      bounds.height > 0,
      visibleContentRect.width > 0,
      visibleContentRect.height > 0,
      visibleCanvasFrame.width > 0,
      visibleCanvasFrame.height > 0
    else {
      return canvasRadius
    }

    let drawableScaleX = CGFloat(pixelWidth) / bounds.width
    let drawableScaleY = CGFloat(pixelHeight) / bounds.height
    let pixelScaleX = visibleCanvasFrame.width * drawableScaleX / visibleContentRect.width
    let pixelScaleY = visibleCanvasFrame.height * drawableScaleY / visibleContentRect.height
    let pixelScale = max((pixelScaleX + pixelScaleY) * 0.5, 0.0001)
    return canvasRadius * Double(pixelScale)
  }

  private func viewportSourceImage(
    _ source: CIImage,
    pixelWidth: Int,
    pixelHeight: Int
  ) -> CIImage? {
    let key = MetalBrushViewportSourceTextureKey(
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
      options: [.colorSpace: MetalBrushSandboxImageProcessing.colorSpace]
    ) else {
      return nil
    }

    let cachedSource = MetalBrushViewportSourceTexture(
      key: key,
      texture: sourceTexture,
      image: sourceImage.cropped(to: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
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
      colorSpace: MetalBrushSandboxImageProcessing.colorSpace
    )
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }

  private func renderViewportCachedComposite(
    baseImage: CIImage,
    blurredImage: CIImage,
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
    encodeClearTexture(textures.baseTexture, commandBuffer: commandBuffer)
    encodeClearTexture(textures.blurredTexture, commandBuffer: commandBuffer)
    renderCachedViewportImage(baseImage, into: textures.baseTexture, commandBuffer: commandBuffer)
    renderCachedViewportImage(blurredImage, into: textures.blurredTexture, commandBuffer: commandBuffer)
    encodeCommittedStrokesForViewport(into: textures.maskTexture, commandBuffer: commandBuffer)

    descriptor.colorAttachments[0].loadAction = .clear
    descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    descriptor.colorAttachments[0].storeAction = .store

    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
      return
    }

    encoder.setRenderPipelineState(tileCompositePipeline)
    encoder.setFragmentTexture(textures.maskTexture, index: 0)
    encoder.setFragmentTexture(textures.baseTexture, index: 1)
    encoder.setFragmentTexture(textures.blurredTexture, index: 2)
    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    encoder.endEncoding()

    commandBuffer.present(drawable)
    commandBuffer.commit()
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
      colorSpace: MetalBrushSandboxImageProcessing.colorSpace
    )
  }

  private func renderViewportComposite(
    _ renderImages: MetalBrushSandboxRenderImages,
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
    encodeClearTexture(textures.baseTexture, commandBuffer: commandBuffer)
    encodeClearTexture(textures.blurredTexture, commandBuffer: commandBuffer)
    renderViewportImage(renderImages.base, into: textures.baseTexture, commandBuffer: commandBuffer)
    renderViewportImage(renderImages.blurred, into: textures.blurredTexture, commandBuffer: commandBuffer)
    encodeCommittedStrokesForViewport(into: textures.maskTexture, commandBuffer: commandBuffer)

    descriptor.colorAttachments[0].loadAction = .clear
    descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    descriptor.colorAttachments[0].storeAction = .store

    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
      return
    }

    encoder.setRenderPipelineState(tileCompositePipeline)
    encoder.setFragmentTexture(textures.maskTexture, index: 0)
    encoder.setFragmentTexture(textures.baseTexture, index: 1)
    encoder.setFragmentTexture(textures.blurredTexture, index: 2)
    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    encoder.endEncoding()

    commandBuffer.present(drawable)
    commandBuffer.commit()
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
    let drawableScaleX = CGFloat(texture.width) / bounds.width
    let drawableScaleY = CGFloat(texture.height) / bounds.height
    let destinationFrame = CGRect(
      x: visibleCanvasFrame.minX * drawableScaleX,
      y: visibleCanvasFrame.minY * drawableScaleY,
      width: visibleCanvasFrame.width * drawableScaleX,
      height: visibleCanvasFrame.height * drawableScaleY
    )
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
      colorSpace: MetalBrushSandboxImageProcessing.colorSpace
    )
  }

  private func viewportTextures(
    pixelWidth: Int,
    pixelHeight: Int
  ) -> MetalBrushViewportRenderTextures? {
    if let textures = viewportRenderTextures,
       textures.pixelWidth == pixelWidth,
       textures.pixelHeight == pixelHeight
    {
      return textures
    }

    guard
      let baseTexture = makeRenderTexture(
        pixelFormat: .bgra8Unorm,
        width: pixelWidth,
        height: pixelHeight
      ),
      let blurredTexture = makeRenderTexture(
        pixelFormat: .bgra8Unorm,
        width: pixelWidth,
        height: pixelHeight
      ),
      let maskTexture = makeRenderTexture(
        pixelFormat: .rgba8Unorm,
        width: pixelWidth,
        height: pixelHeight
      )
    else {
      return nil
    }

    let textures = MetalBrushViewportRenderTextures(
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      baseTexture: baseTexture,
      blurredTexture: blurredTexture,
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

  private func encodeCommittedStrokesForViewport(
    into texture: MTLTexture,
    commandBuffer: MTLCommandBuffer
  ) {
    let visible = visibleContentRect
    let viewportFrame = visibleCanvasFrame
    guard
      committedStrokes.isEmpty == false,
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

    for stroke in committedStrokes where stroke.bounds.intersects(visible) {
      let radius = CGFloat(stroke.brush.size / 2)
      let pixelRadius = Float(Double(radius) * Double((pixelScaleX + pixelScaleY) * 0.5))
      let hardness = Float(stroke.brush.hardness)
      let opacity = Float(stroke.brush.opacity)

      for stamp in stroke.stamps {
        let stampMinX = stamp.x - radius
        let stampMinY = stamp.y - radius
        let stampMaxX = stamp.x + radius
        let stampMaxY = stamp.y + radius
        if stampMaxX < visible.minX || stampMinX > visible.maxX
          || stampMaxY < visible.minY || stampMinY > visible.maxY
        {
          continue
        }

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

    encoder.endEncoding()
  }

  private func hasRenderableCommittedStroke(in canvasRect: CGRect) -> Bool {
    committedStrokes.contains { stroke in
      stroke.bounds.intersects(canvasRect) && stroke.stamps.isEmpty == false
    }
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

  private func clampedContentPoint(_ point: CGPoint) -> CGPoint {
    CGPoint(
      x: min(max(point.x, 0), canvasSize.width),
      y: min(max(point.y, 0), canvasSize.height)
    )
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

  fileprivate static func makeTileCompositePipeline(
    device: MTLDevice,
    library: MTLLibrary
  ) throws -> MTLRenderPipelineState {
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "displayVertex")
    descriptor.fragmentFunction = library.makeFunction(name: "tileCompositeFragment")
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    return try device.makeRenderPipelineState(descriptor: descriptor)
  }

  private static func makeShaderLibrary(device: MTLDevice) throws -> MTLLibrary {
    try device.makeDefaultLibrary(bundle: .main)
  }
}
