import CoreImage
import BrightroomEngine
import MetalKit
import UIKit

private struct EditingCanvasRenderInputKey: Equatable {
  var sourceExtent: CGRect
  var displayBounds: CGRect
  var filters: EditingStack.Edit.Filters
  var mode: EditingCanvasMode
  var renderedPreviewLocalAdjustments: [EditingStack.Edit.LocalAdjustmentLayer]?
}

@_spi(Development)
public final class _EditingCanvasView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {

  private let canvasSize: CGSize
  private let scrollView = _EditingCanvasScrollView()
  private let attachmentContentView = _EditingCanvasAttachmentContentView()
  private let viewportCanvasView = _EditingCanvasViewportCanvasView()
  private let viewportGestureView = _EditingCanvasViewportGestureView()
  private let drawingGestureRecognizer = _EditingCanvasDrawingGestureRecognizer(
    target: nil,
    action: nil
  )
  private let doubleTapZoomGestureRecognizer = UITapGestureRecognizer()
  private let canvasView: _EditingCanvasMTKView?
  private let fallbackLabel = UILabel()
  private var didSetInitialZoom = false
  private var interactionMode: EditingCanvasInteractionMode = .draw
  private var displayedContentRect: CGRect?
  private var lastAppliedDisplayedContentRect: CGRect?
  private var lastAppliedScrollContentBounds: CGRect?
  private var previousLayoutBoundsSize: CGSize = .zero
  private var viewportRenderingDisplayLink: CADisplayLink?
  private var viewportRenderingStopWorkItem: DispatchWorkItem?
  private weak var protectedNavigationController: UINavigationController?
  private var previousInteractivePopGestureEnabled: Bool?
  private weak var currentEditingStack: EditingStack?
  private var currentMode: EditingCanvasMode = .viewportBase
  private var currentLocalEffect: EditingStack.Edit.LocalAdjustmentEffect?
  private var currentRenderInputKey: EditingCanvasRenderInputKey?
  private var editingCanvasLocalAdjustmentLayerID: UUID?
  public var onMetricsChange: ((EditingCanvasMetrics) -> Void)?

  public init(canvasSize: CGSize) {
    self.canvasSize = canvasSize
    self.canvasView = MTLCreateSystemDefaultDevice().map {
      _EditingCanvasMTKView(canvasSize: canvasSize, device: $0)
    }

    super.init(frame: .zero)

    backgroundColor = .clear
    isOpaque = false
    accessibilityIdentifier = "editing-canvas-view"

    scrollView.delegate = self
    scrollView.backgroundColor = .clear
    scrollView.isOpaque = false
    scrollView.showsVerticalScrollIndicator = false
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.bouncesZoom = true
    scrollView.delaysContentTouches = false
    scrollView.canCancelContentTouches = true
    scrollView.panGestureRecognizer.minimumNumberOfTouches = interactionMode.panMinimumNumberOfTouches
    addSubview(scrollView)

    attachmentContentView.frame = CGRect(origin: .zero, size: canvasSize)
    attachmentContentView.bounds = CGRect(origin: .zero, size: canvasSize)
    scrollView.addSubview(attachmentContentView)
    scrollView.addSubview(viewportCanvasView)
    scrollView.addSubview(viewportGestureView)
    scrollView.contentSize = canvasSize

    if let canvasView {
      canvasView.frame = viewportCanvasView.bounds
      canvasView.isUserInteractionEnabled = false
      canvasView.onMetricsChange = { [weak self] in
        self?.publishMetrics()
      }
      canvasView.onStrokeCommit = { [weak self] record, completion in
        self?.commit(record: record, completion: completion)
      }
      canvasView.setViewportCachedSourceEnabled(true)
      viewportCanvasView.addSubview(canvasView)
    } else {
      fallbackLabel.text = "Metal is unavailable"
      fallbackLabel.textColor = .white
      fallbackLabel.textAlignment = .center
      viewportCanvasView.addSubview(fallbackLabel)
    }

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
    viewportGestureView.addGestureRecognizer(drawingGestureRecognizer)

    doubleTapZoomGestureRecognizer.numberOfTapsRequired = 2
    doubleTapZoomGestureRecognizer.delegate = self
    doubleTapZoomGestureRecognizer.addTarget(self, action: #selector(handleDoubleTapZoom(_:)))
    viewportGestureView.addGestureRecognizer(doubleTapZoomGestureRecognizer)
    applyInteractionMode()
  }

  @available(*, unavailable)
  public required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    stopViewportInteractionRendering()
    restoreNavigationBackGesture()
  }

  public override func didMoveToWindow() {
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

  public func configure(
    mode: EditingCanvasMode,
    interactionMode: EditingCanvasInteractionMode,
    brush: EditingCanvasBrush,
    smoothing: EditingCanvasStrokeSmoothingConfiguration
  ) {
    if self.interactionMode != interactionMode {
      self.interactionMode = interactionMode
      applyInteractionMode()
    }
    if currentMode != mode {
      setEditingStackIfPossible(mode: mode)
    }
    canvasView?.configure(brush: brush, smoothing: smoothing)
    updateVisibleContentRect()
  }

  public func configure(
    interactionMode: EditingCanvasInteractionMode,
    localEffect: EditingStack.Edit.LocalAdjustmentEffect,
    brush: EditingCanvasBrush,
    smoothing: EditingCanvasStrokeSmoothingConfiguration
  ) {
    configure(
      interactionMode: interactionMode,
      localEffect: Optional(localEffect),
      brush: brush,
      smoothing: smoothing
    )
  }

  private func configure(
    interactionMode: EditingCanvasInteractionMode,
    localEffect: EditingStack.Edit.LocalAdjustmentEffect?,
    brush: EditingCanvasBrush,
    smoothing: EditingCanvasStrokeSmoothingConfiguration
  ) {
    configure(
      mode: localEffect.map { .localAdjustment(effect: $0) } ?? .viewportBase,
      interactionMode: interactionMode,
      brush: brush,
      smoothing: smoothing
    )
  }

  public func setDisplayedContentRect(_ rect: CGRect?) {
    let sanitizedRect = sanitizedDisplayedContentRect(rect)
    guard displayedContentRect != sanitizedRect else {
      return
    }

    displayedContentRect = sanitizedRect
    lastAppliedDisplayedContentRect = nil
    setNeedsLayout()
    updateScrollContentGeometry()
    updateZoomScaleIfNeeded(refitsToMinimum: false)
    applyDisplayedContentRectIfNeeded()
    updateViewportLayerFrames()
    updateVisibleContentRect()
  }

  private func applyInteractionMode() {
    let isDrawingEnabled = interactionMode.isDrawingEnabled
    if isDrawingEnabled == false {
      canvasView?.cancelStroke()
    }

    drawingGestureRecognizer.isEnabled = isDrawingEnabled
    doubleTapZoomGestureRecognizer.isEnabled = interactionMode == .view
    scrollView.panGestureRecognizer.minimumNumberOfTouches = interactionMode.panMinimumNumberOfTouches
  }

  @objc
  private func handleDoubleTapZoom(_ recognizer: UITapGestureRecognizer) {
    guard recognizer.state == .ended, interactionMode == .view else {
      return
    }

    let tapPoint = recognizer.location(in: viewportGestureView)
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
      .intersection(displayBoundsRect)

    guard zoomRect.isNull == false, zoomRect.isEmpty == false else {
      return
    }

    scrollView.zoom(to: zoomRect, animated: true)
  }

  public func setEditingStack(
    _ editingStack: EditingStack,
    mode: EditingCanvasMode
  ) {
    guard let loadedState = editingStack.loadedState else {
      return
    }

    let localEffect = mode.activeLocalEffect
    let didChangeStack = currentEditingStack !== editingStack
    let didChangeMode = currentMode != mode
    let didChangeLocalEffect = currentLocalEffect != localEffect
    let renderInputKey = makeRenderInputKey(loadedState: loadedState, mode: mode)
    let didChangeRenderInput = currentRenderInputKey != renderInputKey
    currentEditingStack = editingStack
    currentMode = mode
    currentLocalEffect = localEffect

    if didChangeLocalEffect {
      if localEffect == nil {
        editingCanvasLocalAdjustmentLayerID = nil
      }
      updateEditingCanvasLocalAdjustmentEffect(localEffect)
    }

    guard didChangeStack
      || didChangeMode
      || didChangeLocalEffect
      || didChangeRenderInput
      || canvasView?.hasRenderImages == false
    else {
      syncCommittedStrokesFromEditingStack()
      return
    }

    updateRenderImages(loadedState: loadedState, mode: mode, key: renderInputKey)
    syncCommittedStrokesFromEditingStack()
  }

  public func setEditingStack(
    _ editingStack: EditingStack,
    localEffect: EditingStack.Edit.LocalAdjustmentEffect
  ) {
    setEditingStack(editingStack, localEffect: Optional(localEffect))
  }

  private func setEditingStack(
    _ editingStack: EditingStack,
    localEffect: EditingStack.Edit.LocalAdjustmentEffect?
  ) {
    setEditingStack(
      editingStack,
      mode: localEffect.map { .localAdjustment(effect: $0) } ?? .viewportBase
    )
  }

  public func reloadEditingStackPreview() {
    guard
      let editingStack = currentEditingStack,
      let loadedState = editingStack.loadedState
    else {
      return
    }

    updateRenderImages(
      loadedState: loadedState,
      mode: currentMode,
      key: makeRenderInputKey(loadedState: loadedState, mode: currentMode)
    )
    syncCommittedStrokesFromEditingStack()
  }

  private func setEditingStackIfPossible(mode: EditingCanvasMode) {
    guard let currentEditingStack else {
      currentMode = mode
      currentLocalEffect = mode.activeLocalEffect
      return
    }

    setEditingStack(currentEditingStack, mode: mode)
  }

  public func reset() {
    canvasView?.reset()
    canvasView?.setCommittedStrokes([])
    if let currentEditingStack {
      currentEditingStack.set(localAdjustments: [])
    }
    editingCanvasLocalAdjustmentLayerID = nil
    updateVisibleContentRect()
    publishMetrics()
  }

  private func commit(record: EditingCanvasStrokeRecord, completion: @escaping () -> Void) {
    appendRecordToEditingStack(record)
    syncCommittedStrokesFromEditingStack()
    completion()
    publishMetrics()
  }

  private func updateRenderImages(
    loadedState: EditingStack.Loaded,
    mode: EditingCanvasMode,
    key: EditingCanvasRenderInputKey
  ) {
    guard let images = makeCanvasRenderImages(loadedState: loadedState, mode: mode) else {
      return
    }

    canvasView?.setRenderImages(images)
    currentRenderInputKey = key
  }

  private func makeRenderInputKey(
    loadedState: EditingStack.Loaded,
    mode: EditingCanvasMode
  ) -> EditingCanvasRenderInputKey {
    let previewSourceImage = loadedState.editingSourceImage.removingExtentOffset()
    return .init(
      sourceExtent: previewSourceImage.extent,
      displayBounds: displayBoundsRect,
      filters: loadedState.currentEdit.filters,
      mode: mode,
      renderedPreviewLocalAdjustments: mode.rendersFullEditPreview ? loadedState.currentEdit.localAdjustments : nil
    )
  }

  private func makeCanvasRenderImages(
    loadedState: EditingStack.Loaded,
    mode: EditingCanvasMode
  ) -> EditingCanvasRenderImages? {
    EditingCanvasRenderImageFactory.makeRenderImages(
      loadedState: loadedState,
      canvasSize: canvasSize,
      displayedContentRect: displayBoundsRect,
      mode: mode
    )
  }

  private func appendRecordToEditingStack(_ record: EditingCanvasStrokeRecord) {
    guard let currentEditingStack, let currentLocalEffect else {
      return
    }

    var localAdjustments = currentEditingStack.loadedState?.currentEdit.localAdjustments ?? []
    let layerIndex: Int
    if let existingIndex = editingCanvasLayerIndex(in: localAdjustments) {
      layerIndex = existingIndex
    } else {
      let id = UUID()
      editingCanvasLocalAdjustmentLayerID = id
      localAdjustments.append(
        .init(
          id: id,
          effect: currentLocalEffect,
          mask: .init()
        )
      )
      layerIndex = localAdjustments.index(before: localAdjustments.endIndex)
    }

    localAdjustments[layerIndex].isEnabled = true
    localAdjustments[layerIndex].effect = currentLocalEffect
    localAdjustments[layerIndex].mask.strokes.append(record.localAdjustmentStroke)
    currentEditingStack.set(localAdjustments: localAdjustments)
  }

  private func updateEditingCanvasLocalAdjustmentEffect(
    _ localEffect: EditingStack.Edit.LocalAdjustmentEffect?
  ) {
    guard let currentEditingStack, let localEffect else {
      return
    }

    var localAdjustments = currentEditingStack.loadedState?.currentEdit.localAdjustments ?? []
    guard let layerIndex = editingCanvasLayerIndex(in: localAdjustments) else {
      return
    }

    guard localAdjustments[layerIndex].effect != localEffect else {
      return
    }

    localAdjustments[layerIndex].effect = localEffect
    currentEditingStack.set(localAdjustments: localAdjustments)
  }

  private func syncCommittedStrokesFromEditingStack() {
    let localAdjustments = currentEditingStack?.loadedState?.currentEdit.localAdjustments ?? []
    guard let layerIndex = editingCanvasLayerIndex(in: localAdjustments) else {
      canvasView?.setCommittedStrokes([])
      publishMetrics()
      return
    }

    let records = localAdjustments[layerIndex].mask.strokes.map {
      EditingCanvasStrokeRecord(localAdjustmentStroke: $0)
    }
    canvasView?.setCommittedStrokes(records)
    publishMetrics()
  }

  private func editingCanvasLayerIndex(
    in localAdjustments: [EditingStack.Edit.LocalAdjustmentLayer]
  ) -> Int? {
    guard let currentLocalEffect else {
      return nil
    }

    if
      let editingCanvasLocalAdjustmentLayerID,
      let index = localAdjustments.firstIndex(where: { $0.id == editingCanvasLocalAdjustmentLayerID })
    {
      return index
    }

    guard let index = localAdjustments.firstIndex(where: { layer in
      layer.effect.editingCanvasEffectIdentity == currentLocalEffect.editingCanvasEffectIdentity
    }) else {
      return nil
    }

    editingCanvasLocalAdjustmentLayerID = localAdjustments[index].id
    return index
  }

  public override func layoutSubviews() {
    super.layoutSubviews()

    protectNavigationBackGesture()

    let previousBoundsSize = previousLayoutBoundsSize
    let boundsSizeChanged = previousBoundsSize != .zero && previousBoundsSize != bounds.size
    let visibleCenter = boundsSizeChanged ? visibleContentCenter() : nil
    let shouldRefitToMinimumZoom = isAtMinimumZoomScale

    if boundsSizeChanged {
      lastAppliedDisplayedContentRect = nil
    }

    previousLayoutBoundsSize = bounds.size
    scrollView.frame = bounds
    updateScrollContentGeometry()
    updateViewportLayerFrames()

    updateZoomScaleIfNeeded(refitsToMinimum: shouldRefitToMinimumZoom)
    let didApplyDisplayedContentRect = applyDisplayedContentRectIfNeeded()
    if didApplyDisplayedContentRect == false {
      centerContentIfNeeded()
      restoreVisibleContentCenterIfNeeded(visibleCenter)
    }
    updateViewportLayerFrames()
    updateVisibleContentRect()
    publishMetrics()
  }

  public func viewForZooming(in scrollView: UIScrollView) -> UIView? {
    attachmentContentView
  }

  public func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
    beginViewportInteractionRendering()
  }

  public func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
    updateVisibleContentRect()
    scheduleStopViewportInteractionRendering()
    publishMetrics()
  }

  public func scrollViewDidZoom(_ scrollView: UIScrollView) {
    keepViewportInteractionRenderingAlive()
    centerContentIfNeeded()
    updateViewportLayerFrames()
    updateVisibleContentRect()
    publishMetrics()
  }

  public func scrollViewDidScroll(_ scrollView: UIScrollView) {
    if isZoomInteractionActive {
      keepViewportInteractionRenderingAlive()
    }
    updateViewportLayerFrames()
    updateVisibleContentRect()
    publishMetrics()
  }

  public func gestureRecognizer(
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

  private var isZoomInteractionActive: Bool {
    scrollView.isZooming
      || scrollView.isZoomBouncing
      || scrollView.pinchGestureRecognizer?.state.isActiveEditingCanvasGestureState == true
  }

  private var displayBoundsRect: CGRect {
    displayedContentRect ?? CGRect(origin: .zero, size: canvasSize)
  }

  private func updateScrollContentGeometry() {
    let displayBounds = displayBoundsRect
    guard lastAppliedScrollContentBounds != displayBounds
      || attachmentContentView.bounds != displayBounds
    else {
      return
    }

    attachmentContentView.bounds = displayBounds
    attachmentContentView.frame = CGRect(origin: .zero, size: displayBounds.size)
    scrollView.contentSize = displayBounds.size
    lastAppliedScrollContentBounds = displayBounds
  }

  private func updateViewportLayerFrames() {
    let viewportFrame = CGRect(
      origin: scrollView.bounds.origin,
      size: scrollView.bounds.size
    )

    viewportCanvasView.frame = viewportFrame
    viewportGestureView.frame = viewportFrame

    canvasView?.frame = viewportCanvasView.bounds
    canvasView?.contentScaleFactor = window?.screen.scale ?? UIScreen.main.scale
    fallbackLabel.frame = viewportCanvasView.bounds
  }

  private func updateZoomScaleIfNeeded(refitsToMinimum: Bool) {
    guard bounds.width > 0, bounds.height > 0 else {
      return
    }

    let displayBounds = displayBoundsRect
    let fitScale = min(
      bounds.width / max(displayBounds.width, 1),
      bounds.height / max(displayBounds.height, 1)
    )
    let minimumZoomScale = min(fitScale, 1)

    scrollView.minimumZoomScale = minimumZoomScale
    scrollView.maximumZoomScale = max(16, minimumZoomScale * 8)

    if didSetInitialZoom == false {
      didSetInitialZoom = true
      scrollView.setZoomScale(minimumZoomScale, animated: false)
      return
    }

    guard isZoomInteractionActive == false else {
      return
    }

    if refitsToMinimum || scrollView.zoomScale < minimumZoomScale {
      scrollView.setZoomScale(minimumZoomScale, animated: false)
    } else if scrollView.zoomScale > scrollView.maximumZoomScale {
      scrollView.setZoomScale(scrollView.maximumZoomScale, animated: false)
    }
  }

  @discardableResult
  private func applyDisplayedContentRectIfNeeded() -> Bool {
    guard
      let displayedContentRect,
      bounds.width > 0,
      bounds.height > 0,
      displayedContentRect.width > 0,
      displayedContentRect.height > 0,
      isZoomInteractionActive == false,
      lastAppliedDisplayedContentRect != displayedContentRect
    else {
      return false
    }

    let zoomScale = min(
      max(
        min(
          bounds.width / displayedContentRect.width,
          bounds.height / displayedContentRect.height
        ),
        scrollView.minimumZoomScale
      ),
      scrollView.maximumZoomScale
    )

    scrollView.setZoomScale(zoomScale, animated: false)
    centerContentIfNeeded()

    let displayBounds = displayBoundsRect
    let proposedOffset = CGPoint(
      x: (displayedContentRect.midX - displayBounds.minX) * zoomScale - scrollView.bounds.width / 2,
      y: (displayedContentRect.midY - displayBounds.minY) * zoomScale - scrollView.bounds.height / 2
    )

    scrollView.setContentOffset(
      clampedContentOffset(proposedOffset),
      animated: false
    )
    lastAppliedDisplayedContentRect = displayedContentRect
    return true
  }

  private func sanitizedDisplayedContentRect(_ rect: CGRect?) -> CGRect? {
    guard let rect else {
      return nil
    }

    let canvasRect = CGRect(origin: .zero, size: canvasSize)
    let finiteRect = rect.standardized
    guard
      finiteRect.isNull == false,
      finiteRect.isInfinite == false,
      finiteRect.width > 0,
      finiteRect.height > 0
    else {
      return nil
    }

    let intersection = canvasRect.intersection(finiteRect)
    guard intersection.isNull == false, intersection.isEmpty == false else {
      return nil
    }

    return intersection
  }

  private func centerContentIfNeeded() {
    let contentSize = zoomedScrollContentSize
    let horizontalInset = max((scrollView.bounds.width - contentSize.width) / 2, 0)
    let verticalInset = max((scrollView.bounds.height - contentSize.height) / 2, 0)

    scrollView.contentInset = UIEdgeInsets(
      top: verticalInset,
      left: horizontalInset,
      bottom: verticalInset,
      right: horizontalInset
    )
  }

  private func visibleContentCenter() -> CGPoint? {
    let visibleRect = scrollView.convert(scrollView.bounds, to: attachmentContentView)
      .intersection(displayBoundsRect)

    guard visibleRect.isNull == false, visibleRect.isEmpty == false else {
      return nil
    }

    return CGPoint(x: visibleRect.midX, y: visibleRect.midY)
  }

  private func restoreVisibleContentCenterIfNeeded(_ center: CGPoint?) {
    guard let center else {
      return
    }

    let displayBounds = displayBoundsRect
    let scaledCenter = CGPoint(
      x: (center.x - displayBounds.minX) * scrollView.zoomScale,
      y: (center.y - displayBounds.minY) * scrollView.zoomScale
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
    let contentSize = zoomedScrollContentSize
    let minimumX = -scrollView.contentInset.left
    let minimumY = -scrollView.contentInset.top
    let maximumX = max(
      minimumX,
      contentSize.width - scrollView.bounds.width + scrollView.contentInset.right
    )
    let maximumY = max(
      minimumY,
      contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom
    )

    return CGPoint(
      x: min(max(contentOffset.x, minimumX), maximumX),
      y: min(max(contentOffset.y, minimumY), maximumY)
    )
  }

  private var zoomedScrollContentSize: CGSize {
    let displayBounds = displayBoundsRect
    return CGSize(
      width: displayBounds.width * scrollView.zoomScale,
      height: displayBounds.height * scrollView.zoomScale
    )
  }

  private func updateVisibleContentRect() {
    let displayBounds = displayBoundsRect
    let viewportContentRect = scrollView.convert(scrollView.bounds, to: attachmentContentView)
    let liveVisibleRect = viewportContentRect
      .intersection(displayBounds)

    let effectiveLiveRect: CGRect
    if liveVisibleRect.isNull || liveVisibleRect.isEmpty {
      effectiveLiveRect = displayBounds
    } else {
      effectiveLiveRect = liveVisibleRect
    }
    let visibleCanvasFrame = attachmentContentView.convert(effectiveLiveRect, to: viewportCanvasView)

    canvasView?.setViewport(
      visibleContentRect: effectiveLiveRect,
      visibleCanvasFrame: visibleCanvasFrame,
      zoomScale: scrollView.zoomScale
    )

  }

  private func beginViewportInteractionRendering() {
    guard canvasView != nil, viewportRenderingDisplayLink == nil else {
      return
    }

    let displayLink = CADisplayLink(
      target: self,
      selector: #selector(viewportRenderingDisplayLinkDidTick(_:))
    )
    displayLink.preferredFramesPerSecond = window?.screen.maximumFramesPerSecond
      ?? UIScreen.main.maximumFramesPerSecond
    displayLink.add(to: .main, forMode: .common)
    viewportRenderingDisplayLink = displayLink
  }

  private func keepViewportInteractionRenderingAlive() {
    beginViewportInteractionRendering()
    scheduleStopViewportInteractionRendering()
  }

  private func scheduleStopViewportInteractionRendering() {
    viewportRenderingStopWorkItem?.cancel()

    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      if self.isZoomInteractionActive {
        self.scheduleStopViewportInteractionRendering()
      } else {
        self.stopViewportInteractionRendering()
      }
    }

    viewportRenderingStopWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
  }

  private func stopViewportInteractionRendering() {
    viewportRenderingStopWorkItem?.cancel()
    viewportRenderingStopWorkItem = nil
    viewportRenderingDisplayLink?.invalidate()
    viewportRenderingDisplayLink = nil
    canvasView?.setNeedsDisplay()
  }

  @objc private func viewportRenderingDisplayLinkDidTick(_ displayLink: CADisplayLink) {
    updateViewportLayerFrames()
    updateVisibleContentRect()
    canvasView?.setNeedsDisplay()
  }

  private func contentPoint(fromViewportPoint point: CGPoint) -> CGPoint {
    viewportGestureView.convert(point, to: attachmentContentView)
  }

  private func publishMetrics() {
    let activeStamps = canvasView?.activeStampCount ?? 0
    let committedStamps = canvasView?.committedStampCount ?? 0
    onMetricsChange?(
      EditingCanvasMetrics(
        zoomScale: Double(scrollView.zoomScale),
        stampCount: activeStamps + committedStamps,
        strokeCount: canvasView?.strokeCount ?? 0,
        framesPerSecond: canvasView?.framesPerSecond ?? 0
      )
    )
  }
}

private extension UIGestureRecognizer.State {
  var isActiveEditingCanvasGestureState: Bool {
    switch self {
    case .began, .changed:
      return true
    case .possible, .ended, .cancelled, .failed:
      return false
    @unknown default:
      return false
    }
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
