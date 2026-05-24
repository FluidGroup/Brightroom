import CoreImage
import BrightroomEngine
import IOSurface
import MetalKit
import os
import simd
import SwiftUI
import UIKit

struct MetalBrushTilePosition: Hashable {
  let col: Int
  let row: Int

  var logDescription: String {
    "(\(col),\(row))"
  }
}

enum MetalBrushTileRenderReason: String {
  case missingContents
  case contentsScaleChanged
  case contentChanged
  case strokeCommit
  case tileGridChanged
  case tileGridRetry
}

struct MetalBrushTileRenderRequest {
  let entry: MetalBrushTileEntry
  let reason: MetalBrushTileRenderReason
}

enum MetalBrushSandboxRenderLog {
  private static let logger = Logger(
    subsystem: "SwiftUIDemo",
    category: "MetalBrushSandboxRender"
  )

  static func debug(_ message: @autoclosure () -> String) {
#if DEBUG
    let text = message()
    logger.debug("\(text, privacy: .public)")
#endif
  }

  static func error(_ message: @autoclosure () -> String) {
#if DEBUG
    let text = message()
    logger.error("\(text, privacy: .public)")
#endif
  }
}

struct MetalBrushTileRenderState {
  var generation = 0
  var isRetired = false
}

final class MetalBrushTileEntry {
  let position: MetalBrushTilePosition
  let layer: CALayer
  let canvasRect: CGRect
  var renderedContentsScale: CGFloat = 0
  var displayBuffer: MetalBrushTileDisplayBuffer?
  private let renderStateLock = OSAllocatedUnfairLock<MetalBrushTileRenderState>(
    initialState: .init()
  )

  init(position: MetalBrushTilePosition, layer: CALayer, canvasRect: CGRect) {
    self.position = position
    self.layer = layer
    self.canvasRect = canvasRect
  }

  func makeRenderGeneration() -> Int {
    renderStateLock.withLock { state in
      state.isRetired = false
      state.generation += 1
      return state.generation
    }
  }

  func retire() {
    renderStateLock.withLock { state in
      state.isRetired = true
      state.generation += 1
    }
  }

  func isRenderCurrent(_ generation: Int) -> Bool {
    renderStateLock.withLock { state in
      state.isRetired == false && state.generation == generation
    }
  }
}

struct MetalBrushTilePixelSize: Hashable {
  let width: Int
  let height: Int
}

final class MetalBrushTileDisplayBuffer {
  let pixelSize: MetalBrushTilePixelSize
  let surface: IOSurface
  let texture: MTLTexture

  init?(
    pixelWidth: Int,
    pixelHeight: Int,
    device: MTLDevice
  ) {
    let bytesPerRow = pixelWidth * 4
    let attrs: [IOSurfacePropertyKey: Any] = [
      .allocSize: bytesPerRow * pixelHeight,
      .width: pixelWidth,
      .height: pixelHeight,
      .bytesPerElement: 4,
      .bytesPerRow: bytesPerRow,
      .cacheMode: 0,
      .name: "MetalBrushSandboxTile",
      .pixelFormat: NSNumber(value: kCVPixelFormatType_32BGRA),
      .pixelSizeCastingAllowed: true,
    ]
    guard let surface = IOSurface(properties: attrs) else { return nil }

    let descriptor = MTLTextureDescriptor()
    descriptor.pixelFormat = .bgra8Unorm
    descriptor.width = pixelWidth
    descriptor.height = pixelHeight
    descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
    descriptor.storageMode = .shared
    guard let texture = device.makeTexture(
      descriptor: descriptor,
      iosurface: surface,
      plane: 0
    ) else {
      return nil
    }

    self.pixelSize = .init(width: pixelWidth, height: pixelHeight)
    self.surface = surface
    self.texture = texture
  }
}

final class MetalBrushTileScratchBuffers {
  let baseTexture: MTLTexture
  let blurredTexture: MTLTexture
  let maskTexture: MTLTexture

  init(
    baseTexture: MTLTexture,
    blurredTexture: MTLTexture,
    maskTexture: MTLTexture
  ) {
    self.baseTexture = baseTexture
    self.blurredTexture = blurredTexture
    self.maskTexture = maskTexture
  }
}

enum MetalBrushTileDisplayContent {
  case buffer(MetalBrushTileDisplayBuffer)

  var layerContents: Any {
    switch self {
    case .buffer(let buffer):
      return buffer.surface
    }
  }
}

struct MetalBrushSandboxRenderImages {
  let source: CIImage
  let filters: EditingStack.Edit.Filters
  let base: CIImage
  let blurred: CIImage
  let blurRadius: Double
  let hasLocalEffect: Bool
}

final class MetalBrushSandboxCommittedCanvasView: UIView {

  struct RendererContext {
    let device: MTLDevice
    let brushPipeline: MTLRenderPipelineState
    let tileCompositePipeline: MTLRenderPipelineState
    let ciContext: CIContext
    let colorSpace: CGColorSpace
    var renderImages: MetalBrushSandboxRenderImages?
  }

  private let canvasSize: CGSize
  // Tile frames live in canvas points. Their IOSurface pixel size is
  // frame.size * contentsScale, so zooming out can use one large logical layer
  // backed by a display-resolution texture instead of original-resolution pixels.
  private let targetTilePixelSize: CGFloat = 1024
  private let minimumTilePointSize: CGFloat = 16
  private let maxContentsScale: CGFloat = 64
  private let interactiveLODChangeRatio: CGFloat = 1.5
  private let tileTransitionRenderRetryLimit = 2
  private let scratchBufferCacheLimit = 4
  private let renderContentGenerationLock = OSAllocatedUnfairLock<Int>(initialState: 0)
  private let strokesLock = OSAllocatedUnfairLock<[MetalBrushSandboxStrokeRecord]>(initialState: [])
  private var tiles: [MetalBrushTilePosition: MetalBrushTileEntry] = [:]
  private var currentContentsScale: CGFloat = 0
  private var currentTilePointSize: CGFloat = 0
  private var visibleContentRect: CGRect = .zero
  private var tileGridTransitionGeneration = 0
  private var retainedTransitionLayers: [CALayer] = []
  private var rendererContext: RendererContext?
  private var tileQueue: MTLCommandQueue?
  private var scratchBuffersByPixelSize: [MetalBrushTilePixelSize: MetalBrushTileScratchCacheEntry] = [:]
  private var scratchBufferUseCounter = 0
  private let renderQueue = DispatchQueue(
    label: "metal-brush-sandbox.tile-render",
    qos: .userInitiated
  )

  private struct ScheduledTileRender {
    let entry: MetalBrushTileEntry
    let reason: MetalBrushTileRenderReason
    let generation: Int
    let strokes: [MetalBrushSandboxStrokeRecord]
    let canvasRect: CGRect
    let contentsScale: CGFloat
    let pixelWidth: Int
    let pixelHeight: Int
    let rendererContext: RendererContext
    let tileQueue: MTLCommandQueue
    let contentGeneration: Int
  }

  private struct RenderedTile {
    let scheduled: ScheduledTileRender
    let displayContent: MetalBrushTileDisplayContent
  }

  private struct MetalBrushTileScratchCacheEntry {
    var buffers: MetalBrushTileScratchBuffers
    var lastUse: Int
  }

  var strokeCount: Int {
    strokesLock.withLock { $0.count }
  }

  var committedStampCount: Int {
    strokesLock.withLock { strokes in
      strokes.reduce(0) { $0 + $1.stamps.count }
    }
  }

  init(canvasSize: CGSize) {
    self.canvasSize = canvasSize
    super.init(frame: CGRect(origin: .zero, size: canvasSize))

    backgroundColor = .clear
    isOpaque = false
    accessibilityIdentifier = "metal-brush-committed-canvas-view"
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func setRendererContext(_ context: RendererContext) {
    rendererContext = context
    tileQueue = context.device.makeCommandQueue()
  }

  func setRenderImages(_ images: MetalBrushSandboxRenderImages?) {
    markRenderContentChanged()
    rendererContext?.renderImages = images
    let entriesNeedingRender = syncVisibleTiles(
      schedulesRender: false,
      forcesRender: true,
      forcedRenderReason: .contentChanged
    )
    scheduleBatchedRender(entriesNeedingRender, completion: nil)
  }

  func setStrokes(_ records: [MetalBrushSandboxStrokeRecord]) {
    markRenderContentChanged()
    strokesLock.withLock {
      $0 = records
    }
    let entriesNeedingRender = syncVisibleTiles(
      schedulesRender: false,
      forcesRender: true,
      forcedRenderReason: .contentChanged
    )
    scheduleBatchedRender(entriesNeedingRender, completion: nil)
  }

  func addStroke(_ record: MetalBrushSandboxStrokeRecord, completion: (() -> Void)? = nil) {
    markRenderContentChanged()
    strokesLock.withLock { $0.append(record) }
    invalidateTiles(intersecting: record.bounds, completion: completion)
  }

  func reset() {
    markRenderContentChanged()
    strokesLock.withLock { $0.removeAll(keepingCapacity: true) }
    for (_, entry) in tiles {
      removeTileEntry(entry)
    }
    tiles.removeAll(keepingCapacity: true)
    removeRetainedTransitionLayers()
    currentContentsScale = 0
    currentTilePointSize = 0
  }

  func setViewport(
    visibleContentRect rawRect: CGRect,
    zoomScale: CGFloat,
    isInteracting: Bool
  ) {
    let canvasRect = CGRect(origin: .zero, size: canvasSize)
    let clipped = rawRect.intersection(canvasRect)
    visibleContentRect = clipped.isNull || clipped.isEmpty ? canvasRect : clipped

    let targetScale = targetContentsScale(for: zoomScale)
    let scaleChanged = abs(currentContentsScale - targetScale) > 0.001
    let shouldApplyScaleChange = currentContentsScale == 0
      || (
        scaleChanged
          && (isInteracting == false || shouldApplyLODChangeDuringInteraction(from: currentContentsScale, to: targetScale))
      )
    if shouldApplyScaleChange {
      currentContentsScale = targetScale
    }
    if currentContentsScale == 0 {
      currentContentsScale = targetScale
    }

    let targetTilePointSize = targetTilePointSize(for: zoomScale)
    let tileSizeChanged = abs(currentTilePointSize - targetTilePointSize) > 0.01
    let shouldApplyTileSizeChange = currentTilePointSize == 0
      || (
        tileSizeChanged
          && (isInteracting == false || shouldApplyLODChangeDuringInteraction(from: currentTilePointSize, to: targetTilePointSize))
      )
    if shouldApplyTileSizeChange {
      if currentTilePointSize != 0, tileSizeChanged {
        MetalBrushSandboxRenderLog.debug(
          "viewport triggers grid transition zoom=\(zoomScale.logString) visible=\(visibleContentRect.logDescription) tilePointSize \(currentTilePointSize.logString)->\(targetTilePointSize.logString) contentsScale current=\(currentContentsScale.logString) target=\(targetScale.logString) interacting=\(isInteracting)"
        )
        transitionTileGrid(to: targetTilePointSize)
        return
      }
      currentTilePointSize = targetTilePointSize
    }
    if currentTilePointSize == 0 {
      currentTilePointSize = targetTilePointSize
    }

    if shouldApplyScaleChange || shouldApplyTileSizeChange {
      MetalBrushSandboxRenderLog.debug(
        "viewport applied zoom=\(zoomScale.logString) visible=\(visibleContentRect.logDescription) contentsScale=\(currentContentsScale.logString) targetScale=\(targetScale.logString) tilePointSize=\(currentTilePointSize.logString) targetTilePointSize=\(targetTilePointSize.logString) interacting=\(isInteracting)"
      )
    }

    if shouldApplyScaleChange && scaleChanged {
      let entriesNeedingRender = syncVisibleTiles(
        schedulesRender: false,
        defaultRenderReason: .contentsScaleChanged
      )
      scheduleBatchedRender(entriesNeedingRender, completion: nil)
    } else {
      syncVisibleTiles()
    }
  }

  private func targetContentsScale(for zoomScale: CGFloat) -> CGFloat {
    let screenScale = window?.screen.scale ?? UIScreen.main.scale
    // This is the display-density scale for canvas points under UIScrollView zoom.
    // It intentionally drops below screenScale when zoomed out.
    return min(max(zoomScale, 0.01) * screenScale, maxContentsScale)
  }

  private func targetTilePointSize(for zoomScale: CGFloat) -> CGFloat {
    let contentsScale = targetContentsScale(for: zoomScale)
    let maxTilePointSize = max(canvasSize.width, canvasSize.height)
    let tilePointSize = targetTilePixelSize / max(contentsScale, 0.01)
    return min(max(tilePointSize, minimumTilePointSize), maxTilePointSize)
  }

  private func shouldApplyLODChangeDuringInteraction(from current: CGFloat, to target: CGFloat) -> Bool {
    guard current > 0, target > 0 else {
      return true
    }
    let ratio = max(current, target) / min(current, target)
    return ratio >= interactiveLODChangeRatio
  }

  @discardableResult
  private func syncVisibleTiles(
    schedulesRender: Bool = true,
    hidesCreatedLayers: Bool = false,
    forcesRender: Bool = false,
    defaultRenderReason: MetalBrushTileRenderReason = .missingContents,
    forcedRenderReason: MetalBrushTileRenderReason = .contentChanged
  ) -> [MetalBrushTileRenderRequest] {
    guard rendererContext != nil else { return [] }
    let tilePointSize = currentTilePointSize
    guard tilePointSize > 0 else { return [] }
    let canvasRect = CGRect(origin: .zero, size: canvasSize)
    let margin = tilePointSize
    let visibleWithMargin = visibleContentRect.insetBy(dx: -margin, dy: -margin).intersection(canvasRect)
    guard visibleWithMargin.isNull == false, visibleWithMargin.isEmpty == false else {
      return []
    }

    let minCol = max(Int(floor(visibleWithMargin.minX / tilePointSize)), 0)
    let minRow = max(Int(floor(visibleWithMargin.minY / tilePointSize)), 0)
    let maxCol = Int(floor((visibleWithMargin.maxX - 0.001) / tilePointSize))
    let maxRow = Int(floor((visibleWithMargin.maxY - 0.001) / tilePointSize))

    var requiredPositions: Set<MetalBrushTilePosition> = []
    var requestsNeedingRender: [MetalBrushTileRenderRequest] = []
    if minCol <= maxCol, minRow <= maxRow {
      for row in minRow...maxRow {
        for col in minCol...maxCol {
          let position = MetalBrushTilePosition(col: col, row: row)
          guard let rect = tileCanvasRect(for: position) else { continue }
          requiredPositions.insert(position)
          let entry: MetalBrushTileEntry
          if let existing = tiles[position] {
            entry = existing
          } else {
            entry = makeTileEntry(
              at: position,
              canvasRect: rect,
              isHidden: hidesCreatedLayers
            )
            tiles[position] = entry
          }
          let renderReason: MetalBrushTileRenderReason?
          if forcesRender {
            renderReason = forcedRenderReason
          } else if entry.layer.contents == nil {
            renderReason = defaultRenderReason
          } else if abs(entry.renderedContentsScale - currentContentsScale) > 0.001 {
            renderReason = .contentsScaleChanged
          } else {
            renderReason = nil
          }
          if let renderReason {
            let request = MetalBrushTileRenderRequest(entry: entry, reason: renderReason)
            requestsNeedingRender.append(request)
            if schedulesRender {
              scheduleRender(request)
            }
          }
        }
      }
    }

    let positionsToRemove = tiles.keys.filter { requiredPositions.contains($0) == false }
    for position in positionsToRemove {
      guard let entry = tiles[position] else { continue }
      removeTileEntry(entry)
      tiles[position] = nil
    }

    return requestsNeedingRender
  }

  private func tileCanvasRect(for position: MetalBrushTilePosition) -> CGRect? {
    let tilePointSize = currentTilePointSize
    guard tilePointSize > 0 else { return nil }
    let canvasRect = CGRect(origin: .zero, size: canvasSize)
    let origin = CGPoint(
      x: CGFloat(position.col) * tilePointSize,
      y: CGFloat(position.row) * tilePointSize
    )
    let rect = CGRect(origin: origin, size: CGSize(width: tilePointSize, height: tilePointSize))
      .intersection(canvasRect)
    guard rect.isNull == false, rect.isEmpty == false else { return nil }
    return rect
  }

  private func makeTileEntry(
    at position: MetalBrushTilePosition,
    canvasRect: CGRect,
    isHidden: Bool = false
  ) -> MetalBrushTileEntry {
    let layer = CALayer()
    layer.frame = canvasRect
    layer.actions = [
      "contents": NSNull(),
      "contentsScale": NSNull(),
      "hidden": NSNull(),
      "opacity": NSNull(),
    ]
    layer.isOpaque = false
    layer.isHidden = isHidden
    self.layer.addSublayer(layer)
    MetalBrushSandboxRenderLog.debug(
      "tile create position=\(position.logDescription) rect=\(canvasRect.logDescription) hidden=\(isHidden)"
    )
    return MetalBrushTileEntry(position: position, layer: layer, canvasRect: canvasRect)
  }

  private func transitionTileGrid(to tilePointSize: CGFloat) {
    tileGridTransitionGeneration += 1
    let generation = tileGridTransitionGeneration
    let previousTilePointSize = currentTilePointSize
    let retiringTiles = tiles
    let retiringLayers = retiringTiles.values.map(\.layer)
    retainedTransitionLayers.append(contentsOf: retiringLayers)

    tiles.removeAll(keepingCapacity: true)
    currentTilePointSize = tilePointSize

    let requestsNeedingRender = syncVisibleTiles(
      schedulesRender: false,
      hidesCreatedLayers: true,
      defaultRenderReason: .tileGridChanged
    )
    let entriesNeedingRender = requestsNeedingRender.map(\.entry)
    MetalBrushSandboxRenderLog.debug(
      "grid transition begin generation=\(generation) previousTilePointSize=\(previousTilePointSize.logString) newTilePointSize=\(tilePointSize.logString) retiring=\(retiringTiles.count) new=\(entriesNeedingRender.count)"
    )
    guard requestsNeedingRender.isEmpty == false else {
      completeTileGridTransition(
        generation: generation,
        entries: [],
        retiringTiles: retiringTiles,
        previousTilePointSize: previousTilePointSize,
        retryCount: 0
      )
      return
    }

    scheduleBatchedRender(requestsNeedingRender) { [weak self] in
      self?.completeTileGridTransition(
        generation: generation,
        entries: entriesNeedingRender,
        retiringTiles: retiringTiles,
        previousTilePointSize: previousTilePointSize,
        retryCount: 0
      )
    }
  }

  private func completeTileGridTransition(
    generation: Int,
    entries: [MetalBrushTileEntry],
    retiringTiles: [MetalBrushTilePosition: MetalBrushTileEntry],
    previousTilePointSize: CGFloat,
    retryCount: Int
  ) {
    guard generation == tileGridTransitionGeneration else {
      MetalBrushSandboxRenderLog.debug(
        "grid transition ignored generation=\(generation) current=\(tileGridTransitionGeneration)"
      )
      return
    }

    let visibleEntries = entries.filter { $0.layer.superlayer === layer }
    let hasMissingRenderedTile = visibleEntries.contains { $0.layer.contents == nil }
    guard hasMissingRenderedTile == false else {
      guard retryCount < tileTransitionRenderRetryLimit else {
        MetalBrushSandboxRenderLog.error(
          "grid transition aborting after missing rendered tiles generation=\(generation) missing=\(visibleEntries.filter { $0.layer.contents == nil }.count)"
        )
        abortTileGridTransition(
          generation: generation,
          newEntries: visibleEntries,
          retiringTiles: retiringTiles,
          previousTilePointSize: previousTilePointSize
        )
        return
      }

      let retryRequests = visibleEntries.map {
        MetalBrushTileRenderRequest(entry: $0, reason: .tileGridRetry)
      }
      MetalBrushSandboxRenderLog.debug(
        "grid transition retry generation=\(generation) retry=\(retryCount + 1) entries=\(retryRequests.count)"
      )
      scheduleBatchedRender(retryRequests) { [weak self] in
        self?.completeTileGridTransition(
          generation: generation,
          entries: visibleEntries,
          retiringTiles: retiringTiles,
          previousTilePointSize: previousTilePointSize,
          retryCount: retryCount + 1
        )
      }
      return
    }

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for entry in visibleEntries {
      entry.layer.isHidden = false
    }
    for entry in retiringTiles.values {
      removeTileEntry(entry)
    }
    CATransaction.commit()
    removeRetainedTransitionLayers()
    MetalBrushSandboxRenderLog.debug(
      "grid transition complete generation=\(generation) visible=\(visibleEntries.count) retired=\(retiringTiles.count)"
    )
  }

  private func abortTileGridTransition(
    generation: Int,
    newEntries: [MetalBrushTileEntry],
    retiringTiles: [MetalBrushTilePosition: MetalBrushTileEntry],
    previousTilePointSize: CGFloat
  ) {
    guard generation == tileGridTransitionGeneration else { return }

    MetalBrushSandboxRenderLog.error(
      "grid transition abort generation=\(generation) restoreTilePointSize=\(previousTilePointSize.logString) newEntries=\(newEntries.count) retiring=\(retiringTiles.count)"
    )

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for entry in newEntries {
      removeTileEntry(entry)
    }
    for entry in retiringTiles.values where entry.layer.superlayer == nil {
      layer.addSublayer(entry.layer)
    }
    CATransaction.commit()

    tiles = retiringTiles
    currentTilePointSize = previousTilePointSize
    let retiringLayers = retiringTiles.values.map(\.layer)
    retainedTransitionLayers.removeAll { retainedLayer in
      retiringLayers.contains { $0 === retainedLayer }
    }
  }

  private func invalidateTiles(intersecting bounds: CGRect, completion: (() -> Void)? = nil) {
    let tilePointSize = currentTilePointSize
    guard tilePointSize > 0 else {
      DispatchQueue.main.async {
        completion?()
      }
      return
    }

    let canvasRect = CGRect(origin: .zero, size: canvasSize)
    let visibleWithMargin = visibleContentRect.insetBy(dx: -tilePointSize, dy: -tilePointSize).intersection(canvasRect)
    let intersectingTiles = tiles.filter { $0.value.canvasRect.intersects(bounds) }
    let visibleEntries = intersectingTiles.compactMap { _, entry -> MetalBrushTileEntry? in
      if entry.canvasRect.intersects(visibleWithMargin) {
        return entry
      } else {
        return nil
      }
    }

    for (position, entry) in intersectingTiles where entry.canvasRect.intersects(visibleWithMargin) == false {
      removeTileEntry(entry)
      tiles[position] = nil
    }

    guard visibleEntries.isEmpty == false else {
      MetalBrushSandboxRenderLog.debug(
        "stroke invalidation skipped visibleTiles=0 strokeBounds=\(bounds.logDescription) visibleWithMargin=\(visibleWithMargin.logDescription)"
      )
      DispatchQueue.main.async {
        completion?()
      }
      return
    }

    MetalBrushSandboxRenderLog.debug(
      "stroke invalidation scheduled visibleTiles=\(visibleEntries.count) strokeBounds=\(bounds.logDescription) visibleWithMargin=\(visibleWithMargin.logDescription)"
    )
    scheduleBatchedRender(
      visibleEntries.map { MetalBrushTileRenderRequest(entry: $0, reason: .strokeCommit) },
      completion: completion
    )
  }

  private func removeAllTiles(keepingCapacity: Bool) {
    for (_, entry) in tiles {
      removeTileEntry(entry)
    }
    tiles.removeAll(keepingCapacity: keepingCapacity)
    removeRetainedTransitionLayers()
  }

  private func removeRetainedTransitionLayers(_ layers: [CALayer]? = nil) {
    let layersToRemove = layers ?? retainedTransitionLayers
    for layer in layersToRemove {
      removeTileLayer(layer)
    }

    if layers == nil {
      retainedTransitionLayers.removeAll(keepingCapacity: true)
    } else {
      retainedTransitionLayers.removeAll { retainedLayer in
        layersToRemove.contains { $0 === retainedLayer }
      }
    }
  }

  private func removeTileEntry(_ entry: MetalBrushTileEntry) {
    MetalBrushSandboxRenderLog.debug(
      "tile remove position=\(entry.position.logDescription) rect=\(entry.canvasRect.logDescription)"
    )
    entry.retire()
    entry.layer.contents = nil
    entry.layer.removeFromSuperlayer()
    entry.displayBuffer = nil
    entry.renderedContentsScale = 0
  }

  private func removeTileLayer(_ layer: CALayer) {
    layer.contents = nil
    layer.removeFromSuperlayer()
  }

  private func scheduleRender(_ request: MetalBrushTileRenderRequest, completion: (() -> Void)? = nil) {
    guard let scheduled = makeScheduledRender(for: request) else {
      DispatchQueue.main.async {
        completion?()
      }
      return
    }

    MetalBrushSandboxRenderLog.debug(renderScheduleMessage(scheduled, batchCount: nil))
    renderQueue.async { [weak self] in
      guard let self else { return }
      guard self.isRenderContentCurrent(scheduled) else {
        MetalBrushSandboxRenderLog.debug(self.renderSkipMessage(scheduled, reason: "content-generation-changed-before-render"))
        DispatchQueue.main.async {
          completion?()
        }
        return
      }
      let displayContent: MetalBrushTileDisplayContent? = autoreleasepool {
        guard scheduled.entry.isRenderCurrent(scheduled.generation) else {
          MetalBrushSandboxRenderLog.debug(self.renderSkipMessage(scheduled, reason: "tile-generation-retired-before-render"))
          return nil
        }
        return self.renderTileContent(for: scheduled)
      }
      guard let displayContent else {
        MetalBrushSandboxRenderLog.debug(self.renderSkipMessage(scheduled, reason: "render-returned-empty-content"))
        DispatchQueue.main.async {
          completion?()
        }
        return
      }

      DispatchQueue.main.async {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.applyRenderedTile(.init(scheduled: scheduled, displayContent: displayContent))
        CATransaction.commit()
        completion?()
      }
    }
  }

  private func scheduleBatchedRender(
    _ requests: [MetalBrushTileRenderRequest],
    completion: (() -> Void)?
  ) {
    let scheduledRenders = requests.compactMap(makeScheduledRender)
    guard scheduledRenders.isEmpty == false else {
      DispatchQueue.main.async {
        completion?()
      }
      return
    }

    MetalBrushSandboxRenderLog.debug(
      "batch schedule count=\(scheduledRenders.count) reasons=\(renderReasonSummary(scheduledRenders))"
    )
    renderQueue.async { [weak self] in
      guard let self else { return }

      var renderedTiles: [RenderedTile] = []
      renderedTiles.reserveCapacity(scheduledRenders.count)
      for scheduled in scheduledRenders {
        guard self.isRenderContentCurrent(scheduled) else {
          MetalBrushSandboxRenderLog.debug(self.renderSkipMessage(scheduled, reason: "content-generation-changed-before-render"))
          continue
        }
        let displayContent: MetalBrushTileDisplayContent? = autoreleasepool {
          guard scheduled.entry.isRenderCurrent(scheduled.generation) else {
            MetalBrushSandboxRenderLog.debug(self.renderSkipMessage(scheduled, reason: "tile-generation-retired-before-render"))
            return nil
          }
          return self.renderTileContent(for: scheduled)
        }
        if let displayContent {
          renderedTiles.append(.init(scheduled: scheduled, displayContent: displayContent))
        } else {
          MetalBrushSandboxRenderLog.debug(self.renderSkipMessage(scheduled, reason: "render-returned-empty-content"))
        }
      }

      DispatchQueue.main.async { [weak self] in
        guard let self else {
          completion?()
          return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock {
          completion?()
        }
        for renderedTile in renderedTiles {
          self.applyRenderedTile(renderedTile)
        }
        CATransaction.commit()
      }
    }
  }

  private func makeScheduledRender(for request: MetalBrushTileRenderRequest) -> ScheduledTileRender? {
    guard let rendererContext, let tileQueue else {
      return nil
    }

    let entry = request.entry
    let generation = entry.makeRenderGeneration()
    let canvasRect = entry.canvasRect
    let contentsScale = currentContentsScale
    return ScheduledTileRender(
      entry: entry,
      reason: request.reason,
      generation: generation,
      strokes: strokesLock.withLock { $0 },
      canvasRect: canvasRect,
      contentsScale: contentsScale,
      pixelWidth: alignedPixelSize(canvasRect.width * contentsScale),
      pixelHeight: alignedPixelSize(canvasRect.height * contentsScale),
      rendererContext: rendererContext,
      tileQueue: tileQueue,
      contentGeneration: currentRenderContentGeneration()
    )
  }

  private func markRenderContentChanged() {
    renderContentGenerationLock.withLock {
      $0 += 1
    }
  }

  private func currentRenderContentGeneration() -> Int {
    renderContentGenerationLock.withLock { $0 }
  }

  private func isRenderContentCurrent(_ scheduled: ScheduledTileRender) -> Bool {
    currentRenderContentGeneration() == scheduled.contentGeneration
  }

  private func renderReasonSummary(_ scheduledRenders: [ScheduledTileRender]) -> String {
    let counts = Dictionary(grouping: scheduledRenders, by: \.reason)
      .mapValues(\.count)
      .sorted { $0.key.rawValue < $1.key.rawValue }
      .map { "\($0.key.rawValue):\($0.value)" }
      .joined(separator: ",")
    return "[\(counts)]"
  }

  private func renderScheduleMessage(
    _ scheduled: ScheduledTileRender,
    batchCount: Int?
  ) -> String {
    let batchPrefix = batchCount.map { "batchCount=\($0) " } ?? ""
    return "tile schedule \(batchPrefix)position=\(scheduled.entry.position.logDescription) reason=\(scheduled.reason.rawValue) gen=\(scheduled.generation) contentGen=\(scheduled.contentGeneration) rect=\(scheduled.canvasRect.logDescription) px=\(scheduled.pixelWidth)x\(scheduled.pixelHeight) scale=\(scheduled.contentsScale.logString) strokes=\(scheduled.strokes.count)"
  }

  private func renderSkipMessage(
    _ scheduled: ScheduledTileRender,
    reason: String
  ) -> String {
    "tile skip position=\(scheduled.entry.position.logDescription) reason=\(reason) requestReason=\(scheduled.reason.rawValue) gen=\(scheduled.generation) contentGen=\(scheduled.contentGeneration)"
  }

  private func renderTileContent(for scheduled: ScheduledTileRender) -> MetalBrushTileDisplayContent? {
    let startedAt = CACurrentMediaTime()
    MetalBrushSandboxRenderLog.debug(
      "tile render start position=\(scheduled.entry.position.logDescription) reason=\(scheduled.reason.rawValue) gen=\(scheduled.generation) rect=\(scheduled.canvasRect.logDescription) px=\(scheduled.pixelWidth)x\(scheduled.pixelHeight) scale=\(scheduled.contentsScale.logString) strokes=\(scheduled.strokes.count)"
    )
    guard let displayBuffer = renderTileSurface(
      entry: scheduled.entry,
      canvasRect: scheduled.canvasRect,
      pixelWidth: scheduled.pixelWidth,
      pixelHeight: scheduled.pixelHeight,
      strokes: scheduled.strokes,
      context: scheduled.rendererContext,
      tileQueue: scheduled.tileQueue
    ) else {
      let durationMs = (CACurrentMediaTime() - startedAt) * 1000
      MetalBrushSandboxRenderLog.debug(
        "tile render failed position=\(scheduled.entry.position.logDescription) reason=\(scheduled.reason.rawValue) gen=\(scheduled.generation) durationMs=\(durationMs.logString)"
      )
      return nil
    }
    let durationMs = (CACurrentMediaTime() - startedAt) * 1000
    MetalBrushSandboxRenderLog.debug(
      "tile render finish position=\(scheduled.entry.position.logDescription) reason=\(scheduled.reason.rawValue) gen=\(scheduled.generation) durationMs=\(durationMs.logString)"
    )
    return .buffer(displayBuffer)
  }

  private func applyRenderedTile(_ rendered: RenderedTile) {
    let entry = rendered.scheduled.entry
    guard entry.isRenderCurrent(rendered.scheduled.generation) else {
      MetalBrushSandboxRenderLog.debug(renderSkipMessage(rendered.scheduled, reason: "tile-generation-retired-before-apply"))
      return
    }
    guard entry.layer.superlayer === layer else {
      MetalBrushSandboxRenderLog.debug(renderSkipMessage(rendered.scheduled, reason: "layer-not-attached-before-apply"))
      return
    }

    entry.layer.contentsScale = rendered.scheduled.contentsScale
    entry.layer.contents = rendered.displayContent.layerContents
    entry.renderedContentsScale = rendered.scheduled.contentsScale
    MetalBrushSandboxRenderLog.debug(
      "tile apply position=\(entry.position.logDescription) reason=\(rendered.scheduled.reason.rawValue) gen=\(rendered.scheduled.generation) rect=\(entry.canvasRect.logDescription) px=\(rendered.scheduled.pixelWidth)x\(rendered.scheduled.pixelHeight) scale=\(rendered.scheduled.contentsScale.logString)"
    )
  }

  private func alignedPixelSize(_ value: CGFloat) -> Int {
    let raw = max(Int(value.rounded()), 4)
    return (raw + 3) & ~3
  }

  private func renderTileSurface(
    entry: MetalBrushTileEntry,
    canvasRect: CGRect,
    pixelWidth: Int,
    pixelHeight: Int,
    strokes: [MetalBrushSandboxStrokeRecord],
    context: RendererContext,
    tileQueue: MTLCommandQueue
  ) -> MetalBrushTileDisplayBuffer? {
    guard let renderImages = context.renderImages else {
      MetalBrushSandboxRenderLog.debug(
        "tile render skipped no renderImages position=\(entry.position.logDescription) rect=\(canvasRect.logDescription)"
      )
      return nil
    }

    guard
      let displayBuffer = displayBuffer(
        for: entry,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        device: context.device
      )
    else {
      MetalBrushSandboxRenderLog.error(
        "tile display buffer unavailable position=\(entry.position.logDescription) px=\(pixelWidth)x\(pixelHeight)"
      )
      return nil
    }

    guard let commandBuffer = tileQueue.makeCommandBuffer() else {
      MetalBrushSandboxRenderLog.error(
        "tile command buffer unavailable position=\(entry.position.logDescription)"
      )
      return nil
    }

    guard renderImages.hasLocalEffect, hasRenderableStroke(in: canvasRect, strokes: strokes) else {
      MetalBrushSandboxRenderLog.debug(
        "tile render path=base position=\(entry.position.logDescription) hasLocalEffect=\(renderImages.hasLocalEffect) maskNeeded=false"
      )
      render(
        renderImages.base,
        canvasRect: canvasRect,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        into: displayBuffer.texture,
        context: context,
        commandBuffer: commandBuffer
      )
      commandBuffer.commit()
      commandBuffer.waitUntilCompleted()
      return displayBuffer
    }

    let intersectingStrokeCount = strokes.filter {
      $0.bounds.intersects(canvasRect) && $0.stamps.isEmpty == false
    }.count
    MetalBrushSandboxRenderLog.debug(
      "tile render path=local-blur position=\(entry.position.logDescription) intersectingStrokes=\(intersectingStrokeCount)"
    )
    guard
      let scratchBuffers = scratchBuffers(
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        device: context.device
    )
    else {
      MetalBrushSandboxRenderLog.error(
        "tile scratch buffers unavailable position=\(entry.position.logDescription) px=\(pixelWidth)x\(pixelHeight)"
      )
      return nil
    }

    render(
      renderImages.base,
      canvasRect: canvasRect,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      into: scratchBuffers.baseTexture,
      context: context,
      commandBuffer: commandBuffer
    )
    render(
      renderImages.blurred,
      canvasRect: canvasRect,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      into: scratchBuffers.blurredTexture,
      context: context,
      commandBuffer: commandBuffer
    )

    let clearDescriptor = MTLRenderPassDescriptor()
    clearDescriptor.colorAttachments[0].texture = scratchBuffers.maskTexture
    clearDescriptor.colorAttachments[0].loadAction = .clear
    clearDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    clearDescriptor.colorAttachments[0].storeAction = .store
    commandBuffer.makeRenderCommandEncoder(descriptor: clearDescriptor)?.endEncoding()

    encodeStrokes(
      strokes,
      canvasRect: canvasRect,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      into: scratchBuffers.maskTexture,
      brushPipeline: context.brushPipeline,
      commandBuffer: commandBuffer
    )

    let compositeDescriptor = MTLRenderPassDescriptor()
    compositeDescriptor.colorAttachments[0].texture = displayBuffer.texture
    compositeDescriptor.colorAttachments[0].loadAction = .dontCare
    compositeDescriptor.colorAttachments[0].storeAction = .store
    guard let compositeEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: compositeDescriptor) else {
      return nil
    }

    compositeEncoder.setRenderPipelineState(context.tileCompositePipeline)
    compositeEncoder.setFragmentTexture(scratchBuffers.maskTexture, index: 0)
    compositeEncoder.setFragmentTexture(scratchBuffers.baseTexture, index: 1)
    compositeEncoder.setFragmentTexture(scratchBuffers.blurredTexture, index: 2)
    compositeEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    compositeEncoder.endEncoding()

    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

    return displayBuffer
  }

  private func hasRenderableStroke(
    in canvasRect: CGRect,
    strokes: [MetalBrushSandboxStrokeRecord]
  ) -> Bool {
    strokes.contains { stroke in
      stroke.bounds.intersects(canvasRect) && stroke.stamps.isEmpty == false
    }
  }

  private func displayBuffer(
    for entry: MetalBrushTileEntry,
    pixelWidth: Int,
    pixelHeight: Int,
    device: MTLDevice
  ) -> MetalBrushTileDisplayBuffer? {
    let pixelSize = MetalBrushTilePixelSize(width: pixelWidth, height: pixelHeight)
    if let displayBuffer = entry.displayBuffer,
       displayBuffer.pixelSize == pixelSize
    {
      MetalBrushSandboxRenderLog.debug(
        "display buffer reuse position=\(entry.position.logDescription) px=\(pixelWidth)x\(pixelHeight)"
      )
      return displayBuffer
    }

    MetalBrushSandboxRenderLog.debug(
      "display buffer allocate position=\(entry.position.logDescription) px=\(pixelWidth)x\(pixelHeight)"
    )
    guard let displayBuffer = MetalBrushTileDisplayBuffer(
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      device: device
    ) else {
      MetalBrushSandboxRenderLog.error(
        "display buffer allocation failed position=\(entry.position.logDescription) px=\(pixelWidth)x\(pixelHeight)"
      )
      return nil
    }
    entry.displayBuffer = displayBuffer
    return displayBuffer
  }

  private func scratchBuffers(
    pixelWidth: Int,
    pixelHeight: Int,
    device: MTLDevice
  ) -> MetalBrushTileScratchBuffers? {
    let pixelSize = MetalBrushTilePixelSize(width: pixelWidth, height: pixelHeight)
    scratchBufferUseCounter += 1
    let lastUse = scratchBufferUseCounter
    if var entry = scratchBuffersByPixelSize[pixelSize] {
      entry.lastUse = lastUse
      scratchBuffersByPixelSize[pixelSize] = entry
      MetalBrushSandboxRenderLog.debug(
        "scratch buffers reuse px=\(pixelWidth)x\(pixelHeight) cacheCount=\(scratchBuffersByPixelSize.count)"
      )
      return entry.buffers
    }

    MetalBrushSandboxRenderLog.debug(
      "scratch buffers allocate px=\(pixelWidth)x\(pixelHeight) cacheCount=\(scratchBuffersByPixelSize.count)"
    )
    guard
      let baseTexture = makeTileRenderTexture(
        pixelFormat: .bgra8Unorm,
        width: pixelWidth,
        height: pixelHeight,
        device: device
      ),
      let blurredTexture = makeTileRenderTexture(
        pixelFormat: .bgra8Unorm,
        width: pixelWidth,
        height: pixelHeight,
        device: device
      ),
      let maskTexture = makeTileRenderTexture(
        pixelFormat: .rgba8Unorm,
        width: pixelWidth,
        height: pixelHeight,
        device: device
      )
    else {
      MetalBrushSandboxRenderLog.error(
        "scratch buffers allocation failed px=\(pixelWidth)x\(pixelHeight)"
      )
      return nil
    }

    let scratchBuffers = MetalBrushTileScratchBuffers(
      baseTexture: baseTexture,
      blurredTexture: blurredTexture,
      maskTexture: maskTexture
    )
    scratchBuffersByPixelSize[pixelSize] = .init(
      buffers: scratchBuffers,
      lastUse: lastUse
    )
    pruneScratchBuffersIfNeeded()
    return scratchBuffers
  }

  private func pruneScratchBuffersIfNeeded() {
    guard scratchBuffersByPixelSize.count > scratchBufferCacheLimit else {
      return
    }

    let keysToRemove = scratchBuffersByPixelSize
      .sorted { $0.value.lastUse < $1.value.lastUse }
      .prefix(scratchBuffersByPixelSize.count - scratchBufferCacheLimit)
      .map(\.key)

    for key in keysToRemove {
      MetalBrushSandboxRenderLog.debug(
        "scratch buffers prune px=\(key.width)x\(key.height)"
      )
      scratchBuffersByPixelSize[key] = nil
    }
  }

  private func makeTileRenderTexture(
    pixelFormat: MTLPixelFormat,
    width: Int,
    height: Int,
    device: MTLDevice
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

  private func render(
    _ image: CIImage,
    canvasRect: CGRect,
    pixelWidth: Int,
    pixelHeight: Int,
    into texture: MTLTexture,
    context: RendererContext,
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
    // Core Image samples the original into the tile's destination resolution here.
    // For zoomed-out tiles this is the downscale pass; no full-size bitmap is
    // materialized for the tile before resizing.
    let tileImage = image
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

    context.ciContext.render(
      tileImage,
      to: texture,
      commandBuffer: commandBuffer,
      bounds: renderBounds,
      colorSpace: context.colorSpace
    )
  }

  private func encodeStrokes(
    _ strokes: [MetalBrushSandboxStrokeRecord],
    canvasRect: CGRect,
    pixelWidth: Int,
    pixelHeight: Int,
    into texture: MTLTexture,
    brushPipeline: MTLRenderPipelineState,
    commandBuffer: MTLCommandBuffer
  ) {
    let descriptor = MTLRenderPassDescriptor()
    descriptor.colorAttachments[0].texture = texture
    descriptor.colorAttachments[0].loadAction = .load
    descriptor.colorAttachments[0].storeAction = .store
    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
      return
    }
    encoder.setRenderPipelineState(brushPipeline)

    let scaleX = Double(pixelWidth) / Double(canvasRect.width)
    let scaleY = Double(pixelHeight) / Double(canvasRect.height)
    let scale = (scaleX + scaleY) * 0.5
    let targetSize = SIMD2(Float(pixelWidth), Float(pixelHeight))

    for stroke in strokes where stroke.bounds.intersects(canvasRect) {
      let radius = CGFloat(stroke.brush.size / 2)
      let pixelRadius = Float(Double(radius) * scale)
      let hardness = Float(stroke.brush.hardness)
      let opacity = Float(stroke.brush.opacity)
      for stamp in stroke.stamps {
        let stampMinX = stamp.x - radius
        let stampMinY = stamp.y - radius
        let stampMaxX = stamp.x + radius
        let stampMaxY = stamp.y + radius
        if stampMaxX < canvasRect.minX || stampMinX > canvasRect.maxX
          || stampMaxY < canvasRect.minY || stampMinY > canvasRect.maxY
        {
          continue
        }
        var uniforms = MetalBrushUniforms(
          canvasSize: targetSize,
          center: SIMD2(
            Float((stamp.x - canvasRect.minX) * scaleX),
            Float((stamp.y - canvasRect.minY) * scaleY)
          ),
          radius: pixelRadius,
          hardness: hardness,
          opacity: opacity
        )
        encoder.setVertexBytes(
          &uniforms,
          length: MemoryLayout<MetalBrushUniforms>.stride,
          index: 0
        )
        encoder.setFragmentBytes(
          &uniforms,
          length: MemoryLayout<MetalBrushUniforms>.stride,
          index: 0
        )
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
      }
    }

    encoder.endEncoding()
  }
}
