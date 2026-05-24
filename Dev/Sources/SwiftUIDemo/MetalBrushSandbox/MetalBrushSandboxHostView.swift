import CoreImage
import BrightroomEngine
import IOSurface
import MetalKit
import os
import simd
import SwiftUI
import UIKit

final class MetalBrushSandboxHostView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {

  private let canvasSize: CGSize
  private let scrollView = MetalBrushSandboxScrollView()
  private let attachmentContentView = MetalBrushSandboxAttachmentContentView()
  private let committedCanvasView: MetalBrushSandboxCommittedCanvasView
  private let tiledCanvasView = MetalBrushSandboxTiledCanvasView()
  private let tiledView = MetalBrushSandboxTiledView()
  private let selectionGestureView = MetalBrushSandboxSelectionGestureView()
  private let tiledGestureView = MetalBrushSandboxTiledGestureView()
  private let drawingGestureRecognizer = MetalBrushDrawingGestureRecognizer(
    target: nil,
    action: nil
  )
  private let doubleTapZoomGestureRecognizer = UITapGestureRecognizer()
  private let canvasView: MetalBrushSandboxCanvasView?
  private let fallbackLabel = UILabel()
  private var didSetInitialZoom = false
  private var interactionMode: MetalBrushSandboxInteractionMode = .draw
  private var renderMode: MetalBrushSandboxRenderMode = .full
  private var previousLayoutBoundsSize: CGSize = .zero
  private weak var protectedNavigationController: UINavigationController?
  private var previousInteractivePopGestureEnabled: Bool?
  private weak var currentEditingStack: EditingStack?
  private var currentBlurRadius: Double?
  private var sandboxLocalAdjustmentLayerID: UUID?
  var onMetricsChange: ((MetalBrushSandboxMetrics) -> Void)?

  init(canvasSize: CGSize) {
    self.canvasSize = canvasSize
    self.canvasView = MTLCreateSystemDefaultDevice().map {
      MetalBrushSandboxCanvasView(canvasSize: canvasSize, device: $0)
    }
    self.committedCanvasView = MetalBrushSandboxCommittedCanvasView(canvasSize: canvasSize)

    super.init(frame: .zero)

    backgroundColor = .black
    accessibilityIdentifier = "metal-brush-sandbox-host"

    scrollView.delegate = self
    scrollView.backgroundColor = .clear
    scrollView.isOpaque = false
    scrollView.showsVerticalScrollIndicator = false
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.bouncesZoom = true
    scrollView.alwaysBounceHorizontal = true
    scrollView.alwaysBounceVertical = true
    scrollView.delaysContentTouches = false
    scrollView.canCancelContentTouches = true
    scrollView.panGestureRecognizer.minimumNumberOfTouches = interactionMode.panMinimumNumberOfTouches
    addSubview(scrollView)

    attachmentContentView.frame = CGRect(origin: .zero, size: canvasSize)
    committedCanvasView.frame = attachmentContentView.bounds
    attachmentContentView.addSubview(committedCanvasView)
    scrollView.addSubview(attachmentContentView)
    scrollView.addSubview(tiledCanvasView)
    scrollView.addSubview(tiledView)
    scrollView.contentSize = canvasSize

    if let canvasView, let device = canvasView.sharedDevice {
      canvasView.frame = tiledCanvasView.bounds
      canvasView.isUserInteractionEnabled = false
      canvasView.onMetricsChange = { [weak self] in
        self?.publishMetrics()
      }
      canvasView.onStrokeCommit = { [weak self] record, completion in
        self?.commit(record: record, completion: completion)
      }
      committedCanvasView.setRendererContext(
        .init(
          device: device,
          brushPipeline: canvasView.sharedBrushPipeline,
          tileCompositePipeline: canvasView.sharedTileCompositePipeline,
          ciContext: CIContext(mtlDevice: device),
          colorSpace: MetalBrushSandboxImageProcessing.colorSpace,
          renderImages: nil
        )
      )
      tiledCanvasView.addSubview(canvasView)
    } else {
      fallbackLabel.text = "Metal is unavailable"
      fallbackLabel.textColor = .white
      fallbackLabel.textAlignment = .center
      tiledCanvasView.addSubview(fallbackLabel)
    }

    tiledView.addSubview(selectionGestureView)
    tiledView.addSubview(tiledGestureView)

    drawingGestureRecognizer.delegate = self
    drawingGestureRecognizer.onBegin = { [weak self] point in
      guard let self else { return }
      canvasView?.beginStroke(at: contentPoint(fromViewportPoint: point))
    }
    drawingGestureRecognizer.onMove = { [weak self] points in
      guard let self else { return }
      canvasView?.appendStroke(
        points: points.map { self.contentPoint(fromViewportPoint: $0) }
      )
    }
    drawingGestureRecognizer.onEnd = { [weak self] point in
      guard let self else { return }
      canvasView?.endStroke(at: contentPoint(fromViewportPoint: point))
    }
    drawingGestureRecognizer.onCancel = { [weak canvasView] in
      canvasView?.cancelStroke()
    }
    tiledGestureView.addGestureRecognizer(drawingGestureRecognizer)

    doubleTapZoomGestureRecognizer.numberOfTapsRequired = 2
    doubleTapZoomGestureRecognizer.delegate = self
    doubleTapZoomGestureRecognizer.addTarget(self, action: #selector(handleDoubleTapZoom(_:)))
    tiledGestureView.addGestureRecognizer(doubleTapZoomGestureRecognizer)
    applyInteractionMode()
    applyRenderMode()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    restoreNavigationBackGesture()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()

    if window == nil {
      restoreNavigationBackGesture()
    } else {
      protectNavigationBackGesture()
      DispatchQueue.main.async { [weak self] in
        self?.protectNavigationBackGesture()
      }
    }
  }

  func configure(
    interactionMode: MetalBrushSandboxInteractionMode,
    renderMode: MetalBrushSandboxRenderMode,
    brush: MetalBrushSandboxBrush,
    smoothing: MetalBrushStrokeSmoothingConfiguration
  ) {
    if self.interactionMode != interactionMode {
      self.interactionMode = interactionMode
      applyInteractionMode()
    }
    if self.renderMode != renderMode {
      self.renderMode = renderMode
      applyRenderMode()
      reloadEditingStackTiles()
    }
    canvasView?.configure(brush: brush, smoothing: smoothing)
    updateVisibleContentRect()
  }

  private func applyInteractionMode() {
    let isDrawingEnabled = interactionMode.isDrawingEnabled && renderMode.allowsDrawing
    if isDrawingEnabled == false {
      canvasView?.cancelStroke()
    }

    drawingGestureRecognizer.isEnabled = isDrawingEnabled
    doubleTapZoomGestureRecognizer.isEnabled = interactionMode == .view
    scrollView.panGestureRecognizer.minimumNumberOfTouches = interactionMode.panMinimumNumberOfTouches
  }

  private func applyRenderMode() {
    committedCanvasView.isHidden = renderMode.usesCommittedTiles == false
    canvasView?.setViewportImageRenderingEnabled(renderMode.usesViewportRenderer)
    canvasView?.setViewportCachedSourceEnabled(renderMode.usesViewportCachedSource)
    applyInteractionMode()
  }

  @objc
  private func handleDoubleTapZoom(_ recognizer: UITapGestureRecognizer) {
    guard recognizer.state == .ended, interactionMode == .view else {
      return
    }

    let tapPoint = recognizer.location(in: tiledGestureView)
    let contentPoint = contentPoint(fromViewportPoint: tapPoint)
    let nextZoomScale: CGFloat
    if scrollView.zoomScale <= scrollView.minimumZoomScale * 1.1 {
      nextZoomScale = min(
        scrollView.maximumZoomScale,
        max(1, scrollView.minimumZoomScale * 3)
      )
    } else {
      nextZoomScale = scrollView.minimumZoomScale
    }

    let zoomSize = CGSize(
      width: scrollView.bounds.width / max(nextZoomScale, 0.01),
      height: scrollView.bounds.height / max(nextZoomScale, 0.01)
    )
    let zoomRect = CGRect(
      x: contentPoint.x - zoomSize.width / 2,
      y: contentPoint.y - zoomSize.height / 2,
      width: zoomSize.width,
      height: zoomSize.height
    )
      .intersection(CGRect(origin: .zero, size: canvasSize))

    guard zoomRect.isNull == false, zoomRect.isEmpty == false else {
      return
    }

    scrollView.zoom(to: zoomRect, animated: true)
  }

  func setEditingStack(_ editingStack: EditingStack, blurRadius: Double) {
    guard let loadedState = editingStack.loadedState else {
      return
    }

    let didChangeStack = currentEditingStack !== editingStack
    let didChangeBlur = currentBlurRadius != blurRadius
    currentEditingStack = editingStack
    currentBlurRadius = blurRadius

    if didChangeBlur {
      updateSandboxLocalAdjustmentEffect(blurRadius: blurRadius)
    }

    guard didChangeStack || didChangeBlur || canvasView?.hasRenderImages == false else {
      syncCommittedStrokesFromEditingStack()
      return
    }

    updateRenderImages(loadedState: loadedState, blurRadius: blurRadius)
    syncCommittedStrokesFromEditingStack()
  }

  func reloadEditingStackTiles() {
    guard
      let editingStack = currentEditingStack,
      let loadedState = editingStack.loadedState,
      let blurRadius = currentBlurRadius
    else {
      return
    }

    updateRenderImages(loadedState: loadedState, blurRadius: blurRadius)
    syncCommittedStrokesFromEditingStack()
  }

  func reset() {
    canvasView?.reset()
    canvasView?.setCommittedStrokes([])
    if let currentEditingStack {
      currentEditingStack.set(localAdjustments: [])
    }
    sandboxLocalAdjustmentLayerID = nil
    committedCanvasView.reset()
    updateVisibleContentRect()
    publishMetrics()
  }

  private func commit(record: MetalBrushSandboxStrokeRecord, completion: @escaping () -> Void) {
    appendRecordToEditingStack(record)
    committedCanvasView.addStroke(record, completion: completion)
    publishMetrics()
  }

  private func updateRenderImages(
    loadedState: EditingStack.Loaded,
    blurRadius: Double
  ) {
    guard let images = makeCanvasRenderImages(loadedState: loadedState, blurRadius: blurRadius) else {
      return
    }

    canvasView?.setRenderImages(images)
    if renderMode.usesCommittedTiles {
      committedCanvasView.setRenderImages(images)
    }
  }

  private func makeCanvasRenderImages(
    loadedState: EditingStack.Loaded,
    blurRadius: Double
  ) -> MetalBrushSandboxRenderImages? {
    let canvasRect = CGRect(origin: .zero, size: canvasSize)
    let originalImage = loadedState.makeOriginalCIImage()
    let originalExtent = originalImage.extent
    let sourceImage = originalImage
      .transformed(by: CGAffineTransform(scaleX: 1, y: -1))
      .transformed(by: CGAffineTransform(translationX: 0, y: originalExtent.height))
      .removingExtentOffset()
    let sourceExtent = sourceImage.extent
    guard sourceExtent.width > 0, sourceExtent.height > 0 else {
      return nil
    }

    let scaledSourceImage: CIImage
    if abs(sourceExtent.width - canvasSize.width) > 0.5
      || abs(sourceExtent.height - canvasSize.height) > 0.5
    {
      scaledSourceImage = sourceImage
        .transformed(
          by: CGAffineTransform(
            scaleX: canvasSize.width / sourceExtent.width,
            y: canvasSize.height / sourceExtent.height
          )
        )
        .cropped(to: canvasRect)
    } else {
      scaledSourceImage = sourceImage.cropped(to: canvasRect)
    }

    let baseImage = loadedState.currentEdit.filters
      .apply(to: scaledSourceImage)
      .cropped(to: canvasRect)

    guard renderMode.usesLocalEffectRenderImages else {
      return .init(
        source: scaledSourceImage,
        filters: loadedState.currentEdit.filters,
        base: baseImage,
        blurred: baseImage,
        blurRadius: blurRadius,
        hasLocalEffect: false
      )
    }

    let blurredImage: CIImage
    if blurRadius > 0.01 {
      blurredImage = baseImage
        .clamped(to: canvasRect)
        .applyingFilter(
          "CIGaussianBlur",
          parameters: [kCIInputRadiusKey: blurRadius]
        )
        .cropped(to: canvasRect)
    } else {
      blurredImage = baseImage
    }

    return .init(
      source: scaledSourceImage,
      filters: loadedState.currentEdit.filters,
      base: baseImage,
      blurred: blurredImage,
      blurRadius: blurRadius,
      hasLocalEffect: blurRadius > 0.01
    )
  }

  private func appendRecordToEditingStack(_ record: MetalBrushSandboxStrokeRecord) {
    guard let currentEditingStack else {
      return
    }

    var localAdjustments = currentEditingStack.loadedState?.currentEdit.localAdjustments ?? []
    let layerIndex: Int
    if let existingIndex = sandboxLayerIndex(in: localAdjustments) {
      layerIndex = existingIndex
    } else {
      let id = UUID()
      sandboxLocalAdjustmentLayerID = id
      localAdjustments.append(
        .init(
          id: id,
          effect: .gaussianBlur(radius: CGFloat(currentBlurRadius ?? 0)),
          mask: .init()
        )
      )
      layerIndex = localAdjustments.index(before: localAdjustments.endIndex)
    }

    localAdjustments[layerIndex].isEnabled = true
    localAdjustments[layerIndex].effect = .gaussianBlur(radius: CGFloat(currentBlurRadius ?? 0))
    localAdjustments[layerIndex].mask.strokes.append(record.localAdjustmentStroke)
    currentEditingStack.set(localAdjustments: localAdjustments)
  }

  private func updateSandboxLocalAdjustmentEffect(blurRadius: Double) {
    guard let currentEditingStack else {
      return
    }

    var localAdjustments = currentEditingStack.loadedState?.currentEdit.localAdjustments ?? []
    guard let layerIndex = sandboxLayerIndex(in: localAdjustments) else {
      return
    }

    let nextEffect = EditingStack.Edit.LocalAdjustmentEffect.gaussianBlur(radius: CGFloat(blurRadius))
    guard localAdjustments[layerIndex].effect != nextEffect else {
      return
    }

    localAdjustments[layerIndex].effect = nextEffect
    currentEditingStack.set(localAdjustments: localAdjustments)
  }

  private func syncCommittedStrokesFromEditingStack() {
    let localAdjustments = currentEditingStack?.loadedState?.currentEdit.localAdjustments ?? []
    guard let layerIndex = sandboxLayerIndex(in: localAdjustments) else {
      committedCanvasView.setStrokes([])
      canvasView?.setCommittedStrokes([])
      publishMetrics()
      return
    }

    let records = localAdjustments[layerIndex].mask.strokes.map {
      MetalBrushSandboxStrokeRecord(localAdjustmentStroke: $0)
    }
    committedCanvasView.setStrokes(records)
    canvasView?.setCommittedStrokes(records)
    publishMetrics()
  }

  private func sandboxLayerIndex(
    in localAdjustments: [EditingStack.Edit.LocalAdjustmentLayer]
  ) -> Int? {
    if
      let sandboxLocalAdjustmentLayerID,
      let index = localAdjustments.firstIndex(where: { $0.id == sandboxLocalAdjustmentLayerID })
    {
      return index
    }

    guard let index = localAdjustments.firstIndex(where: { layer in
      if case .gaussianBlur = layer.effect {
        return true
      } else {
        return false
      }
    }) else {
      return nil
    }

    sandboxLocalAdjustmentLayerID = localAdjustments[index].id
    return index
  }

  func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
    updateVisibleContentRect(isInteracting: false)
    publishMetrics()
  }

  override func layoutSubviews() {
    super.layoutSubviews()

    protectNavigationBackGesture()

    let previousBoundsSize = previousLayoutBoundsSize
    let boundsSizeChanged = previousBoundsSize != .zero && previousBoundsSize != bounds.size
    let visibleCenter = boundsSizeChanged ? visibleContentCenter() : nil
    let shouldRefitToMinimumZoom = isAtMinimumZoomScale

    previousLayoutBoundsSize = bounds.size
    scrollView.frame = bounds
    attachmentContentView.bounds = CGRect(origin: .zero, size: canvasSize)
    committedCanvasView.frame = attachmentContentView.bounds
    updateViewportLayerFrames()

    updateZoomScaleIfNeeded(refitsToMinimum: shouldRefitToMinimumZoom)
    centerContentIfNeeded()
    restoreVisibleContentCenterIfNeeded(visibleCenter)
    updateViewportLayerFrames()
    updateVisibleContentRect()
    publishMetrics()
  }

  func viewForZooming(in scrollView: UIScrollView) -> UIView? {
    attachmentContentView
  }

  func scrollViewDidZoom(_ scrollView: UIScrollView) {
    centerContentIfNeeded()
    updateViewportLayerFrames()
    updateVisibleContentRect()
    publishMetrics()
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    updateViewportLayerFrames()
    updateVisibleContentRect()
    publishMetrics()
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    if isDrawingGesture(gestureRecognizer) || isDrawingGesture(otherGestureRecognizer) {
      return isViewportGesture(gestureRecognizer) || isViewportGesture(otherGestureRecognizer)
    }

    return false
  }

  private func isDrawingGesture(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    gestureRecognizer === drawingGestureRecognizer
  }

  private func isViewportGesture(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    gestureRecognizer === scrollView.panGestureRecognizer || gestureRecognizer === scrollView.pinchGestureRecognizer
  }

  private func protectNavigationBackGesture() {
    guard
      window != nil,
      protectedNavigationController == nil,
      let navigationController = enclosingNavigationController
    else {
      return
    }

    protectedNavigationController = navigationController
    previousInteractivePopGestureEnabled = navigationController.interactivePopGestureRecognizer?.isEnabled
    navigationController.interactivePopGestureRecognizer?.isEnabled = false
  }

  private func restoreNavigationBackGesture() {
    guard let navigationController = protectedNavigationController else {
      return
    }

    if let previousInteractivePopGestureEnabled {
      navigationController.interactivePopGestureRecognizer?.isEnabled = previousInteractivePopGestureEnabled
    }

    protectedNavigationController = nil
    previousInteractivePopGestureEnabled = nil
  }

  private var enclosingNavigationController: UINavigationController? {
    navigationControllerFromResponderChain ?? window?.rootViewController?
      .firstNavigationController(containing: self)
  }

  private var navigationControllerFromResponderChain: UINavigationController? {
    var responder: UIResponder? = self

    while let currentResponder = responder {
      if let navigationController = currentResponder as? UINavigationController {
        return navigationController
      }

      if let viewController = currentResponder as? UIViewController {
        return viewController.navigationController
      }

      responder = currentResponder.next
    }

    return nil
  }

  private var isAtMinimumZoomScale: Bool {
    abs(scrollView.zoomScale - scrollView.minimumZoomScale) < 0.001
  }

  private func updateViewportLayerFrames() {
    let viewportFrame = CGRect(
      origin: scrollView.bounds.origin,
      size: scrollView.bounds.size
    )

    tiledCanvasView.frame = viewportFrame
    tiledView.frame = viewportFrame

    canvasView?.frame = tiledCanvasView.bounds
    canvasView?.contentScaleFactor = window?.screen.scale ?? UIScreen.main.scale
    fallbackLabel.frame = tiledCanvasView.bounds

    selectionGestureView.frame = tiledView.bounds
    tiledGestureView.frame = tiledView.bounds
  }

  private func updateZoomScaleIfNeeded(refitsToMinimum: Bool) {
    guard bounds.width > 0, bounds.height > 0 else {
      return
    }

    let fitScale = min(
      bounds.width / max(canvasSize.width, 1),
      bounds.height / max(canvasSize.height, 1)
    )
    let minimumZoomScale = min(fitScale, 1)

    scrollView.minimumZoomScale = minimumZoomScale
    scrollView.maximumZoomScale = max(16, minimumZoomScale * 8)

    if didSetInitialZoom == false {
      didSetInitialZoom = true
      scrollView.setZoomScale(minimumZoomScale, animated: false)
      return
    }

    if refitsToMinimum || scrollView.zoomScale < minimumZoomScale {
      scrollView.setZoomScale(minimumZoomScale, animated: false)
    } else if scrollView.zoomScale > scrollView.maximumZoomScale {
      scrollView.setZoomScale(scrollView.maximumZoomScale, animated: false)
    }
  }

  private func centerContentIfNeeded() {
    let horizontalInset = max((scrollView.bounds.width - scrollView.contentSize.width) / 2, 0)
    let verticalInset = max((scrollView.bounds.height - scrollView.contentSize.height) / 2, 0)

    scrollView.contentInset = UIEdgeInsets(
      top: verticalInset,
      left: horizontalInset,
      bottom: verticalInset,
      right: horizontalInset
    )
  }

  private func visibleContentCenter() -> CGPoint? {
    let visibleRect = scrollView.convert(scrollView.bounds, to: attachmentContentView)
      .intersection(CGRect(origin: .zero, size: canvasSize))

    guard visibleRect.isNull == false, visibleRect.isEmpty == false else {
      return nil
    }

    return CGPoint(x: visibleRect.midX, y: visibleRect.midY)
  }

  private func restoreVisibleContentCenterIfNeeded(_ center: CGPoint?) {
    guard let center else {
      return
    }

    let scaledCenter = CGPoint(
      x: center.x * scrollView.zoomScale,
      y: center.y * scrollView.zoomScale
    )
    let proposedOffset = CGPoint(
      x: scaledCenter.x - scrollView.bounds.width / 2,
      y: scaledCenter.y - scrollView.bounds.height / 2
    )

    scrollView.setContentOffset(
      clampedContentOffset(proposedOffset),
      animated: false
    )
  }

  private func clampedContentOffset(_ contentOffset: CGPoint) -> CGPoint {
    let minimumX = -scrollView.contentInset.left
    let minimumY = -scrollView.contentInset.top
    let maximumX = max(
      minimumX,
      scrollView.contentSize.width - scrollView.bounds.width + scrollView.contentInset.right
    )
    let maximumY = max(
      minimumY,
      scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom
    )

    return CGPoint(
      x: min(max(contentOffset.x, minimumX), maximumX),
      y: min(max(contentOffset.y, minimumY), maximumY)
    )
  }

  private func updateVisibleContentRect(isInteracting: Bool? = nil) {
    let canvasRect = CGRect(origin: .zero, size: canvasSize)
    let viewportContentRect = scrollView.convert(scrollView.bounds, to: attachmentContentView)
    let liveVisibleRect = viewportContentRect
      .intersection(canvasRect)

    let effectiveLiveRect: CGRect
    if liveVisibleRect.isNull || liveVisibleRect.isEmpty {
      effectiveLiveRect = canvasRect
    } else {
      effectiveLiveRect = liveVisibleRect
    }
    let visibleCanvasFrame = attachmentContentView.convert(effectiveLiveRect, to: tiledCanvasView)

    let visibleRect = viewportContentRect
      .insetBy(dx: -2, dy: -2)
      .intersection(canvasRect)

    let effectiveRect: CGRect
    if visibleRect.isNull || visibleRect.isEmpty {
      effectiveRect = canvasRect
    } else {
      effectiveRect = visibleRect
    }

    canvasView?.setViewport(
      visibleContentRect: effectiveLiveRect,
      visibleCanvasFrame: visibleCanvasFrame,
      zoomScale: scrollView.zoomScale
    )

    if renderMode.usesCommittedTiles {
      let interacting = isInteracting ?? (scrollView.isZooming || scrollView.isDragging || scrollView.isDecelerating)
      committedCanvasView.setViewport(
        visibleContentRect: effectiveRect,
        zoomScale: scrollView.zoomScale,
        isInteracting: interacting
      )
    }
  }

  private func contentPoint(fromViewportPoint point: CGPoint) -> CGPoint {
    tiledGestureView.convert(point, to: attachmentContentView)
  }

  private func publishMetrics() {
    let liveStamps = canvasView?.stampCount ?? 0
    let committedStamps = committedCanvasView.committedStampCount
    onMetricsChange?(
      MetalBrushSandboxMetrics(
        zoomScale: Double(scrollView.zoomScale),
        stampCount: liveStamps + committedStamps,
        strokeCount: committedCanvasView.strokeCount
      )
    )
  }
}

extension UIViewController {

  func firstNavigationController(containing descendant: UIView) -> UINavigationController? {
    if let navigationController = self as? UINavigationController,
       descendant.isDescendant(of: navigationController.view) {
      return navigationController
    }

    for child in children {
      if let navigationController = child.firstNavigationController(containing: descendant) {
        return navigationController
      }
    }

    if let presentedViewController,
       let navigationController = presentedViewController.firstNavigationController(
         containing: descendant
       ) {
      return navigationController
    }

    return nil
  }
}
