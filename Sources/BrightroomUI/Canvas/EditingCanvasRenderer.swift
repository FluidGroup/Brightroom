import BrightroomEngine
import BrightroomParametric
import CoreGraphics
import CoreImage
import Foundation
import Metal
import QuartzCore
import simd

/// Geometry and resolution for one source bake. Image replacement invalidates it separately.
private struct EditingCanvasViewportSourceTextureKey: Equatable {
  var sourceExtent: CGRect
  var visibleContentRect: CGRect
  var contentToCanvasTransform: CGAffineTransform
  var pixelWidth: Int
  var pixelHeight: Int
}

/// Retains the source texture and its cropped image until the viewport or source changes.
private struct EditingCanvasViewportSourceTexture {
  let key: EditingCanvasViewportSourceTextureKey
  let texture: MTLTexture
  let image: CIImage
}

/// Reusable mask storage, cleared and rasterized on every composite frame.
private struct EditingCanvasViewportRenderTextures {
  let pixelWidth: Int
  let pixelHeight: Int
  let maskTexture: MTLTexture
}

/// Geometry and resolution within the current render-images generation.
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

/// Everything the image under the post-crop pass depends on. Within one key the
/// drawn frame differs only by the post-crop pass, so moving the crop frame
/// (a crop guide drag) reuses the cached image instead of re-evaluating the
/// effect graph and the brush mask.
private struct EditingCanvasPreFinishCacheKey: Equatable {
  var visibleContentRect: CGRect
  var contentToCanvasTransform: CGAffineTransform
  var viewportSize: CGSize
  var pixelWidth: Int
  var pixelHeight: Int
  var renderImagesGeneration: Int
  var committedStrokesGeneration: Int
}

/// The drawable-resolution image under the post-crop pass, in y-down texture
/// pixels, retained only while a post-crop effect is set.
private struct EditingCanvasPreFinishCache {
  let key: EditingCanvasPreFinishCacheKey
  let texture: MTLTexture
  let image: CIImage
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

/// The rendering route taken by a frame, reported by performance diagnostics.
private enum EditingCanvasViewportRenderPath: String {
  case clear
  case baseImage = "base-image"
  case cachedSourceBase = "cached-source-base"
  case coreImageComposite = "core-image-composite"
  case cachedPreFinish = "cached-pre-finish"
}

/// Content-space image recipes supplied by the host for one source/effects revision.
/// The renderer retains these until replacement and places them through its viewport.
struct EditingCanvasRenderImages {
  let source: CIImage
  let base: CIImage
  let adjusted: CIImage
  /// Whether `base` applies global effects over `source`. When it does not,
  /// the renderer may sample the cached source instead of evaluating `base`.
  let hasGlobalEffects: Bool
  /// Whether `adjusted` applies a local effect over `base`.
  let hasLocalEffect: Bool
  let usesPreparedBaseImage: Bool
}

/// Owns the image recipes and GPU resources used to render one editing canvas.
///
/// Effects are evaluated in the content domain before viewport placement.
/// Cache mutation and command submission share this main-actor owner and one
/// command queue. The host owns input gestures, frame timing, and presentation.
@MainActor
final class EditingCanvasRenderer {

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

  /// An in-flight stroke sampled for one draw, in y-down content coordinates.
  /// The renderer does not retain it or construct a committed record from it.
  struct ActiveStroke {
    let brush: EditingCanvasBrush
    let stamps: [CGPoint]
  }

  /// The destination and transient inputs consumed by a synchronous render.
  /// `viewportSize` is the fixed canvas size in points, not content pixels.
  /// The descriptor's first color attachment must target `texture`.
  struct Frame {
    let texture: MTLTexture
    let renderPassDescriptor: MTLRenderPassDescriptor
    let viewportSize: CGSize
    let activeStroke: ActiveStroke?
    let preferredFramesPerSecond: Int
  }

  /// An effect the feature evaluates after its final crop, drawn over the
  /// crop frame of every frame.
  ///
  /// The render images hold the feature up to the crop. The pass applies the
  /// effect to the drawable pixels inside `frame`, with `frame` as the
  /// effect's input extent, so an effect that reads its input extent (a
  /// vignette) is centred on the crop output wherever the viewport places it.
  /// Pixels outside the frame are left as they are.
  struct PostCrop: Equatable {
    /// The effect evaluated after the crop.
    var effect: AnyImageEffect
    /// The crop output on the canvas, in canvas points (y-down).
    var frame: CGRect
    /// The chain entry (the whole source) in content coordinates (y-down).
    var chainEntry: CGRect
  }

  /// Retained image inputs and their dependent caches. Content bakes survive
  /// viewport changes; viewport bakes and mask allocations have shorter lifetimes.
  private struct ViewportState: ~Copyable {
    var renderImages: EditingCanvasRenderImages?
    var sourceTexture: EditingCanvasViewportSourceTexture?
    var preparedContentLayers: EditingCanvasPreparedContentLayers?
    var preparedLayersCache: EditingCanvasViewportPreparedLayersCache?
    var renderTextures: EditingCanvasViewportRenderTextures?
    var preFinishCache: EditingCanvasPreFinishCache?
    var postCrop: PostCrop?
    /// Advances on every `setRenderImages`, for the pre-finish cache key.
    var renderImagesGeneration = 0
    /// Advances when the committed strokes change, for the pre-finish cache key.
    var committedStrokesGeneration = 0
    var viewport: Viewport

    init(canvasSize: CGSize) {
      self.viewport = Viewport(
        visibleContentRect: CGRect(origin: .zero, size: canvasSize),
        contentToCanvasTransform: .init(scaleX: 0, y: 0)
      )
    }
  }

  private let canvasSize: CGSize
  private let device: MTLDevice
  private let commandQueue: MTLCommandQueue
  private let brushMaskPipeline: MTLRenderPipelineState
  private var viewportState: ViewportState
  /// A host-supplied projection of committed strokes; the renderer never edits it.
  private var committedRecords: [EditingCanvasStrokeRecord] = []
  #if DEBUG
  private var performanceDiagnostics = PerformanceDiagnostics()

  /// Cache misses since creation, never reset, so tests can tell which
  /// caches a frame rebuilt.
  struct CacheMissCounts: Equatable {
    var sourceTexture = 0
    var renderTextures = 0
    var preparedContentLayers = 0
    var preparedLayers = 0
    var preFinish = 0
  }

  private(set) var cacheMissCounts = CacheMissCounts()
  #endif

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
    self.device = device
    self.commandQueue = device.makeCommandQueue()!
    self.viewportState = ViewportState(canvasSize: canvasSize)
    do {
      self.brushMaskPipeline = try BrushStampPipeline.renderPipelineState(
        device: device,
        pixelFormat: .rgba8Unorm
      )
    } catch {
      fatalError("Failed to create Editing Canvas pipeline: \(error)")
    }
  }

  // MARK: - Rendering inputs

  func setRenderImages(_ images: EditingCanvasRenderImages) {
    viewportState.renderImages = images
    viewportState.renderImagesGeneration &+= 1
    viewportState.preFinishCache = nil
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
  }

  /// Replaces the committed input, returning whether a new frame is needed.
  @discardableResult
  func setCommittedStrokes(_ records: [EditingCanvasStrokeRecord]) -> Bool {
    // Hosts re-send committed strokes on every state update; identical records
    // should not invalidate unchanged rendering inputs.
    guard committedRecords != records else {
      return false
    }

    // Committed strokes are rasterized live every frame (no cache), so updating
    // the records is all that the next externally driven frame needs.
    committedRecords = records
    viewportState.committedStrokesGeneration &+= 1
    viewportState.preFinishCache = nil
    #if DEBUG
    performanceDiagnostics.recordInvalidation(.committedStrokes)
    #endif
    return true
  }

  /// Applies a valid viewport, returning whether its visible mapping changed.
  @discardableResult
  func setViewport(_ viewport: Viewport) -> Bool {
    let transform = viewport.contentToCanvasTransform
    guard
      transform.a.isFinite, transform.b.isFinite,
      transform.c.isFinite, transform.d.isFinite,
      transform.tx.isFinite, transform.ty.isFinite,
      transform.a * transform.d - transform.b * transform.c != 0
    else {
      return false
    }

    var nextViewport = viewport
    let canvasRect = CGRect(origin: .zero, size: canvasSize)
    nextViewport.visibleContentRect = viewport.visibleContentRect.intersection(canvasRect)
    let didChangeViewport = viewportState.viewport.visibleContentRect != nextViewport.visibleContentRect
      || viewportState.viewport.contentToCanvasTransform != transform
    guard didChangeViewport else {
      return false
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
    return true
  }

  /// Sets the effect drawn after the crop, or removes it with a nil `effect`,
  /// returning whether a new frame is needed.
  ///
  /// Moving `frame` alone redraws from the cached image under the pass; the
  /// render images and their bakes are kept. Without an effect the frame is
  /// ignored, so a moving crop frame requests no frames.
  ///
  /// - Parameters:
  ///   - effect: The effect evaluated after the crop.
  ///   - frame: The crop output on the canvas, in canvas points (y-down).
  ///   - chainEntry: The whole source in content coordinates (y-down): the
  ///     chain-entry extent proportional radii resolve against.
  @discardableResult
  func setPostCrop(effect: AnyImageEffect?, frame: CGRect, chainEntry: CGRect) -> Bool {
    let postCrop = effect.map { PostCrop(effect: $0, frame: frame, chainEntry: chainEntry) }
    guard viewportState.postCrop != postCrop else {
      return false
    }
    viewportState.postCrop = postCrop
    if postCrop == nil {
      // The cached image is only read under a pass.
      viewportState.preFinishCache = nil
    }
    #if DEBUG
    performanceDiagnostics.recordInvalidation(.postCrop)
    #endif
    return true
  }

  /// Invalidates only allocations and bakes tied to the drawable size.
  func drawableSizeDidChange() {
    viewportState.renderTextures = nil
    invalidateViewportCoreImageLayerCaches()
    #if DEBUG
    performanceDiagnostics.recordInvalidation(.drawableSize)
    #endif
  }

  // MARK: - Rendering

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

  /// Renders and schedules a frame without presenting a drawable.
  ///
  /// The returned buffer is committed and scheduled. The caller can present
  /// its drawable in the current Core Animation transaction, or wait for GPU
  /// completion before reading an offscreen texture. Frame inputs are not retained.
  func render(_ frame: Frame) -> MTLCommandBuffer? {
    #if DEBUG
    let renderStartTime = CACurrentMediaTime()
    let diagnosticsRenderImages = viewportState.renderImages
    #endif

    guard
      let renderImages = viewportState.renderImages,
      let commandBuffer = commandQueue.makeCommandBuffer(),
      frame.viewportSize.width > 0,
      frame.viewportSize.height > 0,
      viewportState.viewport.visibleContentRect.width > 0,
      viewportState.viewport.visibleContentRect.height > 0,
      viewportState.viewport.visibleCanvasFrame.width > 0,
      viewportState.viewport.visibleCanvasFrame.height > 0
    else {
      let cleared = clearFrame(frame)
      #if DEBUG
      recordPerformanceRender(
        path: .clear,
        startedAt: renderStartTime,
        renderImages: diagnosticsRenderImages,
        texture: nil,
        preferredFramesPerSecond: frame.preferredFramesPerSecond,
        hasRenderableStroke: false
      )
      #endif
      return cleared
    }

    let hasRenderableStroke = hasRenderableStroke(frame, in: viewportState.viewport.visibleContentRect)

    // Only the post-crop pass changed since the cached frame (a crop frame
    // drag): redraw the pass over the cached image.
    if let cachedImage = cachedPreFinishImage(frame: frame) {
      let submitted = renderFinishedDrawable(
        cachedImage,
        frame: frame,
        commandBuffer: commandBuffer,
        cacheKey: nil
      )
      #if DEBUG
      recordPerformanceRender(
        path: .cachedPreFinish,
        startedAt: renderStartTime,
        renderImages: renderImages,
        texture: frame.texture,
        preferredFramesPerSecond: frame.preferredFramesPerSecond,
        hasRenderableStroke: hasRenderableStroke
      )
      #endif
      return submitted
    }

    // Global effects are an open pipeline and may depend on direction, extent,
    // or position. Always evaluate them in content space through `base`, before
    // the viewport affine, so no pan/zoom/rotation can change their domain.
    // Sampling the source cache is equivalent only when global effects are idle.
    if renderImages.usesPreparedBaseImage == false,
       renderImages.hasGlobalEffects == false {
      let result = renderViewportCachedSource(
        renderImages,
        frame: frame,
        commandBuffer: commandBuffer
      )
      #if DEBUG
      recordPerformanceRender(
        path: result.path,
        startedAt: renderStartTime,
        renderImages: renderImages,
        texture: frame.texture,
        preferredFramesPerSecond: frame.preferredFramesPerSecond,
        hasRenderableStroke: hasRenderableStroke
      )
      #endif
      return result.commandBuffer
    }

    guard renderImages.hasLocalEffect,
          hasRenderableStroke
    else {
      // `base` already expresses the global effects in content coordinates.
      // Apply the viewport afterward so navigation preserves that effect domain.
      let submitted = renderViewportBaseImage(
        renderImages.base,
        frame: frame,
        commandBuffer: commandBuffer
      )
      #if DEBUG
      recordPerformanceRender(
        path: .baseImage,
        startedAt: renderStartTime,
        renderImages: renderImages,
        texture: frame.texture,
        preferredFramesPerSecond: frame.preferredFramesPerSecond,
        hasRenderableStroke: hasRenderableStroke
      )
      #endif
      return submitted
    }

    let submitted = renderViewportCoreImageComposite(
      renderImages,
      frame: frame,
      commandBuffer: commandBuffer
    )
    #if DEBUG
    recordPerformanceRender(
      path: .coreImageComposite,
      startedAt: renderStartTime,
      renderImages: renderImages,
      texture: frame.texture,
      preferredFramesPerSecond: frame.preferredFramesPerSecond,
      hasRenderableStroke: hasRenderableStroke
    )
    #endif
    return submitted
  }

  #if DEBUG
  private func recordCacheMiss(_ miss: PerformanceDiagnostics.CacheMiss) {
    performanceDiagnostics.recordCacheMiss(miss)
    switch miss {
    case .sourceTexture: cacheMissCounts.sourceTexture += 1
    case .renderTextures: cacheMissCounts.renderTextures += 1
    case .preparedContentLayers: cacheMissCounts.preparedContentLayers += 1
    case .preparedLayers: cacheMissCounts.preparedLayers += 1
    case .preFinish: cacheMissCounts.preFinish += 1
    }
  }

  private func recordPerformanceRender(
    path: EditingCanvasViewportRenderPath,
    startedAt startTime: CFTimeInterval,
    renderImages: EditingCanvasRenderImages?,
    texture: MTLTexture?,
    preferredFramesPerSecond: Int,
    hasRenderableStroke: Bool
  ) {
    let frameBudget = 1.0 / Double(max(preferredFramesPerSecond, 60))
    let drawableSize = texture.map {
      CGSize(width: CGFloat($0.width), height: CGFloat($0.height))
    }

    performanceDiagnostics.recordRender(
      path: path,
      duration: CACurrentMediaTime() - startTime,
      frameBudget: frameBudget,
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
    frame: Frame,
    commandBuffer: MTLCommandBuffer
  ) -> MTLCommandBuffer {
    let renderBounds = CGRect(
      x: 0,
      y: 0,
      width: frame.texture.width,
      height: frame.texture.height
    )
    let transform = viewportState.viewport.contentToTextureTransform(
      canvasSize: frame.viewportSize,
      textureSize: renderBounds.size
    )
    let visibleImage = image
      .transformed(by: transform)
      .cropped(to: renderBounds)

    return renderDrawableImage(visibleImage, frame: frame, commandBuffer: commandBuffer)
  }

  /// Renders an unadjusted source through its viewport-resolution texture cache.
  /// Any enabled global or local effect uses a content-space prepared image.
  private func renderViewportCachedSource(
    _ renderImages: EditingCanvasRenderImages,
    frame: Frame,
    commandBuffer: MTLCommandBuffer
  ) -> (commandBuffer: MTLCommandBuffer?, path: EditingCanvasViewportRenderPath) {
    let pixelWidth = frame.texture.width
    let pixelHeight = frame.texture.height
    guard
      pixelWidth > 0,
      pixelHeight > 0,
      let sourceImage = viewportSourceImage(
        renderImages.source,
        frame: frame,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight
      )
    else {
      return (clearFrame(frame), .clear)
    }

    let submitted = renderDrawableImage(
      sourceImage,
      frame: frame,
      commandBuffer: commandBuffer
    )
    return (submitted, .cachedSourceBase)
  }

  /// Invalidates ONLY the viewport-scoped layer cache. This runs on every
  /// viewport change (rotation / pan / zoom), so it must NOT drop the
  /// content-scoped bake (`preparedContentLayers`) — that survives viewport
  /// changes and is dropped separately by `invalidatePreparedContentLayers`
  /// when the render images themselves change.
  private func invalidateViewportCoreImageLayerCaches() {
    viewportState.preparedLayersCache = nil
    viewportState.preFinishCache = nil
  }

  /// Drops the adjusted content bake when its image recipe is replaced.
  /// Viewport updates keep this content-space result available for resampling.
  private func invalidatePreparedContentLayers() {
    viewportState.preparedContentLayers = nil
  }

  /// Texture-backed bake of the current `adjusted` (local-effect) layer, built
  /// once per render-images generation. The cache is cleared in
  /// `invalidatePreparedContentLayers` — only on `setRenderImages`, never on
  /// viewport changes — so the composite path samples it instead of re-evaluating
  /// the blur graph, which is
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
    #if DEBUG
    recordCacheMiss(.preparedContentLayers)
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
    frame: Frame,
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
    recordCacheMiss(.sourceTexture)
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
    renderViewportImage(source, into: sourceTexture, frame: frame, commandBuffer: commandBuffer)
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
        frame: frame,
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

  /// Draws a y-down, texture-space image into the drawable, applying the
  /// post-crop pass. Every route that draws the feature ends here.
  private func renderDrawableImage(
    _ image: CIImage,
    frame: Frame,
    commandBuffer: MTLCommandBuffer
  ) -> MTLCommandBuffer {
    renderFinishedDrawable(
      image,
      frame: frame,
      commandBuffer: commandBuffer,
      cacheKey: preFinishCacheKey(frame: frame)
    )
  }

  /// Applies the post-crop pass to `image` and draws the result.
  ///
  /// With a `cacheKey`, `image` is first rendered into a texture in the same
  /// command buffer and published as the pre-finish cache once the buffer is
  /// committed, so later frames that differ only by the pass sample it.
  private func renderFinishedDrawable(
    _ image: CIImage,
    frame: Frame,
    commandBuffer: MTLCommandBuffer,
    cacheKey: EditingCanvasPreFinishCacheKey?
  ) -> MTLCommandBuffer {
    frame.renderPassDescriptor.colorAttachments[0].loadAction = .clear
    frame.renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    frame.renderPassDescriptor.colorAttachments[0].storeAction = .store
    commandBuffer.makeRenderCommandEncoder(descriptor: frame.renderPassDescriptor)?.endEncoding()

    let renderBounds = CGRect(
      x: 0,
      y: 0,
      width: frame.texture.width,
      height: frame.texture.height
    )

    // Texture rows run opposite to the y-down image, so the drawable is the
    // image flipped. The flip maps whole pixels onto whole pixels.
    let flip = CGAffineTransform(scaleX: 1, y: -1)
      .concatenating(.init(translationX: 0, y: renderBounds.height))
    var drawableImage = image
      .transformed(by: flip)
      .cropped(to: renderBounds)

    var newCache: EditingCanvasPreFinishCache?
    if let cacheKey,
       let texture = makeRenderTexture(
         pixelFormat: EditingCanvasImageProcessing.colorTextureFormat,
         width: cacheKey.pixelWidth,
         height: cacheKey.pixelHeight
       )
    {
      #if DEBUG
      recordCacheMiss(.preFinish)
      #endif
      // Bake the drawable image itself, with the same render the drawable
      // gets, so a cached frame shows the same pixels as an uncached one.
      encodeClearTexture(texture, commandBuffer: commandBuffer)
      ciContext.render(
        drawableImage,
        to: texture,
        commandBuffer: commandBuffer,
        bounds: renderBounds,
        colorSpace: EditingCanvasImageProcessing.intermediateColorSpace
      )
      if let bakedImage = CIImage(
        mtlTexture: texture,
        options: [.colorSpace: EditingCanvasImageProcessing.intermediateColorSpace]
      )?.cropped(to: renderBounds) {
        drawableImage = bakedImage
        newCache = .init(
          key: cacheKey,
          texture: texture,
          image: bakedImage.transformed(by: flip).cropped(to: renderBounds)
        )
      }
    }
    let preFinishImage = drawableImage.transformed(by: flip).cropped(to: renderBounds)

    ciContext.render(
      drawableImage,
      to: frame.texture,
      commandBuffer: commandBuffer,
      bounds: renderBounds,
      colorSpace: EditingCanvasImageProcessing.drawableColorSpace
    )

    // The pass replaces only the frame's pixels, in a second write; every
    // pixel outside the frame is the one drawn above, exactly as without a
    // pass. (Compositing the pass over the image in one graph would resample
    // the image's fractional edges differently.)
    if let finished = postCropRegion(preFinishImage, frame: frame, renderBounds: renderBounds) {
      let region = finished.rect.applying(flip).standardized
      let destination = CIRenderDestination(mtlTexture: frame.texture, commandBuffer: commandBuffer)
      destination.colorSpace = EditingCanvasImageProcessing.drawableColorSpace
      do {
        _ = try ciContext.startTask(
          toRender: finished.image.transformed(by: flip).cropped(to: region),
          from: region,
          to: destination,
          at: region.origin
        )
      } catch {
        EditorLog.error(.editingCanvas, "Post-crop pass failed: \(error)")
      }
    }

    let submitted = Self.submit(commandBuffer)
    // Published only after the commit that fills it, so an abandoned frame
    // can never leave an unfilled texture in the cache.
    if let newCache {
      viewportState.preFinishCache = newCache
    }
    return submitted
  }

  /// The post-crop effect applied to the pixels inside the crop frame, and
  /// the whole-pixel rectangle of the drawable it replaces, in y-down texture
  /// pixels; nil when there is no pass or the frame is not on the drawable.
  ///
  /// The frame, rounded to whole pixels, is the effect's input extent, as the
  /// crop output is at export. The image is clamped first, so a frame that
  /// extends beyond the drawable (a zoomed-in viewport) keeps its true centre
  /// and size instead of shrinking to the visible part.
  private func postCropRegion(
    _ image: CIImage,
    frame: Frame,
    renderBounds: CGRect
  ) -> (image: CIImage, rect: CGRect)? {
    guard
      let postCrop = viewportState.postCrop,
      image.extent.isEmpty == false,
      image.extent.isInfinite == false,
      frame.viewportSize.width > 0,
      frame.viewportSize.height > 0
    else {
      return nil
    }

    let canvasToTexture = CGAffineTransform(
      scaleX: renderBounds.width / frame.viewportSize.width,
      y: renderBounds.height / frame.viewportSize.height
    )
    let exactFrame = postCrop.frame.applying(canvasToTexture).standardized
    guard exactFrame.isNull == false, exactFrame.isInfinite == false else {
      return nil
    }
    let minX = exactFrame.minX.rounded()
    let minY = exactFrame.minY.rounded()
    let frameInTexture = CGRect(
      x: minX,
      y: minY,
      width: exactFrame.maxX.rounded() - minX,
      height: exactFrame.maxY.rounded() - minY
    )
    let rect = frameInTexture.intersection(renderBounds)
    guard frameInTexture.isEmpty == false, rect.isNull == false, rect.isEmpty == false else {
      return nil
    }

    let chainEntry = postCrop.chainEntry
      .applying(viewportState.viewport.contentToTextureTransform(
        canvasSize: frame.viewportSize,
        textureSize: renderBounds.size
      ))
      .standardized

    let finished = postCrop.effect
      .applyIgnoringFailure(
        to: image.clampedToExtent().cropped(to: frameInTexture),
        chainEntryExtent: chainEntry
      )
      .cropped(to: rect)
    return (finished, rect)
  }

  /// The key a frame's pre-finish image is cached under, or nil when the
  /// frame is not cached: no post-crop pass, or a live stroke that changes
  /// the image every frame.
  private func preFinishCacheKey(frame: Frame) -> EditingCanvasPreFinishCacheKey? {
    guard
      viewportState.postCrop != nil,
      frame.activeStroke?.stamps.isEmpty ?? true
    else {
      return nil
    }
    return EditingCanvasPreFinishCacheKey(
      visibleContentRect: viewportState.viewport.visibleContentRect,
      contentToCanvasTransform: viewportState.viewport.contentToCanvasTransform,
      viewportSize: frame.viewportSize,
      pixelWidth: frame.texture.width,
      pixelHeight: frame.texture.height,
      renderImagesGeneration: viewportState.renderImagesGeneration,
      committedStrokesGeneration: viewportState.committedStrokesGeneration
    )
  }

  /// The cached pre-finish image when it still represents this frame.
  private func cachedPreFinishImage(frame: Frame) -> CIImage? {
    guard
      let key = preFinishCacheKey(frame: frame),
      let cache = viewportState.preFinishCache,
      cache.key == key
    else {
      return nil
    }
    return cache.image
  }

  private func renderViewportCoreImageComposite(
    _ renderImages: EditingCanvasRenderImages,
    frame: Frame,
    commandBuffer: MTLCommandBuffer
  ) -> MTLCommandBuffer? {
    let pixelWidth = frame.texture.width
    let pixelHeight = frame.texture.height
    guard pixelWidth > 0, pixelHeight > 0 else {
      return clearFrame(frame)
    }

    let renderBounds = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)

    guard
      let preparedLayers = viewportPreparedLayers(
        renderImages,
        frame: frame,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        renderBounds: renderBounds
      )
    else {
      return clearFrame(frame)
    }
    let baseImage = preparedLayers.baseImage
    let adjustedImage = preparedLayers.adjustedImage

    // Committed AND in-flight strokes rasterize through `BrushStampPipeline`
    // every frame — no cache, no intermediate full-canvas texture. Export draws
    // its Core Image tiles with the same pipeline, so the live mask agrees with
    // export by construction. Memory is bounded by the viewport-sized mask
    // texture.
    guard
      hasRenderableStroke(frame, in: viewportState.viewport.visibleContentRect),
      let textures = viewportTextures(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    else {
      return clearFrame(frame)
    }
    encodeClearTexture(textures.maskTexture, commandBuffer: commandBuffer)
    encodeStrokeMaskForViewport(into: textures.maskTexture, frame: frame, commandBuffer: commandBuffer)
    guard
      let maskImage = CIImage(
        mtlTexture: textures.maskTexture,
        options: [.colorSpace: EditingCanvasImageProcessing.maskColorSpace]
      )?.cropped(to: renderBounds)
    else {
      return clearFrame(frame)
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

    return renderDrawableImage(
      compositedImage,
      frame: frame,
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
    frame: Frame,
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
    recordCacheMiss(.preparedLayers)
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
    renderViewportImage(renderImages.base, into: baseTexture, frame: frame, commandBuffer: fillCommandBuffer)
    renderViewportImage(adjustedContent, into: adjustedTexture, frame: frame, commandBuffer: fillCommandBuffer)
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
    frame: Frame,
    commandBuffer: MTLCommandBuffer
  ) {
    let renderBounds = CGRect(
      x: 0,
      y: 0,
      width: texture.width,
      height: texture.height
    )
    let transform = viewportState.viewport.contentToTextureTransform(
      canvasSize: frame.viewportSize,
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

  private func viewportTextureContentFrame(frame: Frame, pixelWidth: Int, pixelHeight: Int) -> CGRect? {
    guard frame.viewportSize.width > 0, frame.viewportSize.height > 0 else {
      return nil
    }

    let transform = viewportState.viewport.contentToTextureTransform(
      canvasSize: frame.viewportSize,
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
    recordCacheMiss(.renderTextures)
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
  /// full-canvas texture. The stamps go through `BrushStampPipeline`, the same
  /// instanced `.max` pass the parametric export draws into Core Image tiles
  /// (`BrushMaskImageProcessor`), so preview and export share one rasterizer.
  /// Cost is O(visible stamp coverage); stamps outside the viewport are skipped.
  private func encodeStrokeMaskForViewport(
    into texture: MTLTexture,
    frame: Frame,
    commandBuffer: MTLCommandBuffer
  ) {
    let viewport = viewportState.viewport
    let visible = viewport.visibleContentRect
    guard
      hasRenderableStroke(frame, in: visible),
      visible.width > 0, visible.height > 0,
      frame.viewportSize.width > 0, frame.viewportSize.height > 0
    else {
      return
    }

    let textureSize = CGSize(width: texture.width, height: texture.height)
    let contentToTextureTransform = viewport.contentToTextureTransform(
      canvasSize: frame.viewportSize,
      textureSize: textureSize
    )
    var stamps: [BrushStampPipeline.Stamp] = []

    func append(_ points: [CGPoint], brush: EditingCanvasBrush) {
      let pixelRadius = Float(viewport.textureRadius(
        forContentRadius: CGFloat(brush.size / 2),
        canvasSize: frame.viewportSize,
        textureSize: textureSize
      ))
      let hardness = Float(brush.hardness)
      let opacity = Float(brush.opacity)

      for point in points {
        let center = point.applying(contentToTextureTransform)
        stamps.append(
          BrushStampPipeline.Stamp(
            center: SIMD2(Float(center.x), Float(center.y)),
            radius: pixelRadius,
            hardness: hardness,
            opacity: opacity
          )
        )
      }
    }

    // Committed strokes share the active stroke's canvas-content coordinate
    // space, so they draw in the same pass.
    for record in committedRecords
    where record.stamps.isEmpty == false && record.bounds.intersects(visible) {
      append(record.stamps, brush: record.brush)
    }

    if let activeStroke = frame.activeStroke {
      append(activeStroke.stamps, brush: activeStroke.brush)
    }

    let descriptor = MTLRenderPassDescriptor()
    descriptor.colorAttachments[0].texture = texture
    descriptor.colorAttachments[0].loadAction = .load
    descriptor.colorAttachments[0].storeAction = .store

    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
      return
    }

    encoder.setRenderPipelineState(brushMaskPipeline)
    BrushStampPipeline.encode(
      stamps,
      targetSize: SIMD2(Float(texture.width), Float(texture.height)),
      into: encoder
    )
    encoder.endEncoding()
  }

  /// Whether any committed or in-flight stroke intersects the viewport. Gates the
  /// composite render path (committed strokes show through the parametric mask
  /// even with no active stroke).
  private func hasRenderableStroke(_ frame: Frame, in canvasRect: CGRect) -> Bool {
    if hasRenderableActiveStroke(frame, in: canvasRect) {
      return true
    }

    return committedRecords.contains { stroke in
      stroke.bounds.intersects(canvasRect) && stroke.stamps.isEmpty == false
    }
  }

  /// Whether the in-flight (active) stroke has stamps intersecting the viewport.
  private func hasRenderableActiveStroke(_ frame: Frame, in canvasRect: CGRect) -> Bool {
    guard let activeStroke = frame.activeStroke else {
      return false
    }
    return activeStroke.stamps.contains {
      stampIntersectsVisibleRect(
        $0,
        radius: CGFloat(activeStroke.brush.size / 2),
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

  private func clearFrame(_ frame: Frame) -> MTLCommandBuffer? {
    guard
      let commandBuffer = commandQueue.makeCommandBuffer()
    else {
      return nil
    }

    frame.renderPassDescriptor.colorAttachments[0].texture = frame.texture
    frame.renderPassDescriptor.colorAttachments[0].loadAction = .clear
    frame.renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    frame.renderPassDescriptor.colorAttachments[0].storeAction = .store
    commandBuffer.makeRenderCommandEncoder(descriptor: frame.renderPassDescriptor)?.endEncoding()
    return Self.submit(commandBuffer)
  }

  /// Submits on the same queue used to fill every retained texture cache.
  private static func submit(_ commandBuffer: MTLCommandBuffer) -> MTLCommandBuffer {
    commandBuffer.commit()
    commandBuffer.waitUntilScheduled()
    return commandBuffer
  }

  #if DEBUG
  /// Debug-only counters for spotting expensive canvas-rendering path drift.
  ///
  /// The summary log is intentionally coarse-grained: it reports path counts,
  /// cache misses, and slow-frame counts once per interval without changing the
  /// render behavior that is being measured.
  /// Duration covers encoding and scheduling, excluding drawable acquisition,
  /// presentation, and GPU completion.
  private struct PerformanceDiagnostics {
    enum CacheMiss: String {
      case sourceTexture = "source-texture"
      case renderTextures = "render-textures"
      case preparedContentLayers = "prepared-content-layers"
      case preparedLayers = "prepared-layers"
      case preFinish = "pre-finish"
    }

    enum Invalidation: String {
      case renderImages = "render-images"
      case committedStrokes = "committed-strokes"
      case viewport = "viewport"
      case drawableSize = "drawable-size"
      case postCrop = "post-crop"
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
    var preFinishMissCount = 0
    var cachedPreFinishFrameCount = 0
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
      case .preFinish:
        preFinishMissCount += 1
      }
    }

    mutating func recordRender(
      path: EditingCanvasViewportRenderPath,
      duration: CFTimeInterval,
      frameBudget: CFTimeInterval,
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
      case .cachedPreFinish:
        cachedPreFinishFrameCount += 1
      }

      let now = CACurrentMediaTime()
      guard now - lastLogTime >= logInterval else {
        return
      }

      EditorLog.debug(.editingCanvasPerformance, """
        [EditingCanvasRender]
        frames:\(frameCount) slow:\(slowFrameCount) budgetMs:\(formatMilliseconds(frameBudget))
        path clear:\(clearFrameCount) base:\(baseImageFrameCount) cachedBase:\(cachedSourceBaseFrameCount) coreComposite:\(coreImageCompositeFrameCount) cachedPreFinish:\(cachedPreFinishFrameCount)
        cacheMiss source:\(sourceTextureMissCount) textures:\(renderTexturesMissCount) contentLayers:\(preparedContentLayersMissCount) preparedLayers:\(preparedLayersMissCount) preFinish:\(preFinishMissCount)
        invalidations:\(invalidationCount) lastInvalidation:\(lastInvalidation?.rawValue ?? "none")
        last path:\(path.rawValue) submitMs:\(formatMilliseconds(duration)) preparedBase:\(usesPreparedBaseImage) localEffect:\(hasLocalEffect) stroke:\(hasRenderableStroke) drawable:\(format(drawableSize))
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
      preFinishMissCount = 0
      cachedPreFinishFrameCount = 0
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

}
