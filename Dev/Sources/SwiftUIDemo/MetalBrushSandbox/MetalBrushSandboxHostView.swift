import CoreImage
import BrightroomEngine
import MetalKit
import UIKit

final class MetalBrushSandboxHostView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {

  private let canvasSize: CGSize
  private let scrollView = MetalBrushSandboxScrollView()
  private let attachmentContentView = MetalBrushSandboxAttachmentContentView()
  private let viewportCanvasView = MetalBrushSandboxViewportCanvasView()
  private let viewportGestureView = MetalBrushSandboxViewportGestureView()
  private let drawingGestureRecognizer = MetalBrushDrawingGestureRecognizer(
    target: nil,
    action: nil
  )
  private let doubleTapZoomGestureRecognizer = UITapGestureRecognizer()
  private let canvasView: MetalBrushSandboxCanvasView?
  private let fallbackLabel = UILabel()
  private var didSetInitialZoom = false
  private var interactionMode: MetalBrushSandboxInteractionMode = .draw
  private var previousLayoutBoundsSize: CGSize = .zero
  private weak var protectedNavigationController: UINavigationController?
  private var previousInteractivePopGestureEnabled: Bool?
  private weak var currentEditingStack: EditingStack?
  private var currentLocalEffect: EditingStack.Edit.LocalAdjustmentEffect?
  private var sandboxLocalAdjustmentLayerID: UUID?
  var onMetricsChange: ((MetalBrushSandboxMetrics) -> Void)?

  init(canvasSize: CGSize) {
    self.canvasSize = canvasSize
    self.canvasView = MTLCreateSystemDefaultDevice().map {
      MetalBrushSandboxCanvasView(canvasSize: canvasSize, device: $0)
    }

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
      canvasView.setViewportImageRenderingEnabled(true)
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
    localEffect: EditingStack.Edit.LocalAdjustmentEffect,
    compositeRenderer: MetalBrushSandboxCompositeRenderer,
    brush: MetalBrushSandboxBrush,
    smoothing: MetalBrushStrokeSmoothingConfiguration
  ) {
    if self.interactionMode != interactionMode {
      self.interactionMode = interactionMode
      applyInteractionMode()
    }
    if self.currentLocalEffect != localEffect {
      setEditingStackIfPossible(localEffect: localEffect)
    }
    canvasView?.setCompositeRenderer(compositeRenderer)
    canvasView?.configure(brush: brush, smoothing: smoothing)
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
      .intersection(CGRect(origin: .zero, size: canvasSize))

    guard zoomRect.isNull == false, zoomRect.isEmpty == false else {
      return
    }

    scrollView.zoom(to: zoomRect, animated: true)
  }

  func setEditingStack(
    _ editingStack: EditingStack,
    localEffect: EditingStack.Edit.LocalAdjustmentEffect
  ) {
    guard let loadedState = editingStack.loadedState else {
      return
    }

    let didChangeStack = currentEditingStack !== editingStack
    let didChangeLocalEffect = currentLocalEffect != localEffect
    currentEditingStack = editingStack
    currentLocalEffect = localEffect

    if didChangeLocalEffect {
      updateSandboxLocalAdjustmentEffect(localEffect)
    }

    guard didChangeStack || didChangeLocalEffect || canvasView?.hasRenderImages == false else {
      syncCommittedStrokesFromEditingStack()
      return
    }

    updateRenderImages(loadedState: loadedState, localEffect: localEffect)
    syncCommittedStrokesFromEditingStack()
  }

  func reloadEditingStackPreview() {
    guard
      let editingStack = currentEditingStack,
      let loadedState = editingStack.loadedState,
      let localEffect = currentLocalEffect
    else {
      return
    }

    updateRenderImages(loadedState: loadedState, localEffect: localEffect)
    syncCommittedStrokesFromEditingStack()
  }

  private func setEditingStackIfPossible(localEffect: EditingStack.Edit.LocalAdjustmentEffect) {
    guard let currentEditingStack else {
      currentLocalEffect = localEffect
      return
    }

    setEditingStack(currentEditingStack, localEffect: localEffect)
  }

  func reset() {
    canvasView?.reset()
    canvasView?.setCommittedStrokes([])
    if let currentEditingStack {
      currentEditingStack.set(localAdjustments: [])
    }
    sandboxLocalAdjustmentLayerID = nil
    updateVisibleContentRect()
    publishMetrics()
  }

  private func commit(record: MetalBrushSandboxStrokeRecord, completion: @escaping () -> Void) {
    appendRecordToEditingStack(record)
    syncCommittedStrokesFromEditingStack()
    completion()
    publishMetrics()
  }

  private func updateRenderImages(
    loadedState: EditingStack.Loaded,
    localEffect: EditingStack.Edit.LocalAdjustmentEffect
  ) {
    guard let images = makeCanvasRenderImages(loadedState: loadedState, localEffect: localEffect) else {
      return
    }

    canvasView?.setRenderImages(images)
  }

  private func makeCanvasRenderImages(
    loadedState: EditingStack.Loaded,
    localEffect: EditingStack.Edit.LocalAdjustmentEffect
  ) -> MetalBrushSandboxRenderImages? {
    let canvasRect = CGRect(origin: .zero, size: canvasSize)
    let previewSourceImage = loadedState.editingSourceImage.removingExtentOffset()
    let sourceExtent = previewSourceImage.extent
    let sourceImage = previewSourceImage
      .transformed(by: CGAffineTransform(scaleX: 1, y: -1))
      .transformed(by: CGAffineTransform(translationX: 0, y: sourceExtent.height))
      .removingExtentOffset()
    let displaySourceExtent = sourceImage.extent
    guard displaySourceExtent.width > 0, displaySourceExtent.height > 0 else {
      return nil
    }

    let scaledSourceImage: CIImage
    if abs(displaySourceExtent.width - canvasSize.width) > 0.5
      || abs(displaySourceExtent.height - canvasSize.height) > 0.5
    {
      scaledSourceImage = sourceImage
        .transformed(
          by: CGAffineTransform(
            scaleX: canvasSize.width / displaySourceExtent.width,
            y: canvasSize.height / displaySourceExtent.height
          )
        )
        .cropped(to: canvasRect)
    } else {
      scaledSourceImage = sourceImage.cropped(to: canvasRect)
    }

    let baseImage = loadedState.currentEdit.filters
      .apply(to: scaledSourceImage)
      .cropped(to: canvasRect)
    let adjustedImage: CIImage
    if localEffect.usesSandboxShaderCompositeExposure {
      adjustedImage = baseImage
    } else {
      adjustedImage = localEffect.apply(to: baseImage, previewScale: 1)
    }

    return .init(
      source: scaledSourceImage,
      filters: loadedState.currentEdit.filters,
      base: baseImage,
      adjusted: adjustedImage,
      localEffect: localEffect
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
          effect: currentLocalEffect ?? .gaussianBlur(radius: 0),
          mask: .init()
        )
      )
      layerIndex = localAdjustments.index(before: localAdjustments.endIndex)
    }

    localAdjustments[layerIndex].isEnabled = true
    localAdjustments[layerIndex].effect = currentLocalEffect ?? .gaussianBlur(radius: 0)
    localAdjustments[layerIndex].mask.strokes.append(record.localAdjustmentStroke)
    currentEditingStack.set(localAdjustments: localAdjustments)
  }

  private func updateSandboxLocalAdjustmentEffect(
    _ localEffect: EditingStack.Edit.LocalAdjustmentEffect
  ) {
    guard let currentEditingStack else {
      return
    }

    var localAdjustments = currentEditingStack.loadedState?.currentEdit.localAdjustments ?? []
    guard let layerIndex = sandboxLayerIndex(in: localAdjustments) else {
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
    guard let layerIndex = sandboxLayerIndex(in: localAdjustments) else {
      canvasView?.setCommittedStrokes([])
      publishMetrics()
      return
    }

    let records = localAdjustments[layerIndex].mask.strokes.map {
      MetalBrushSandboxStrokeRecord(localAdjustmentStroke: $0)
    }
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
      layer.effect.sandboxEffectIdentity == currentLocalEffect?.sandboxEffectIdentity
    }) else {
      return nil
    }

    sandboxLocalAdjustmentLayerID = localAdjustments[index].id
    return index
  }

  func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
    updateVisibleContentRect()
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

  private func updateVisibleContentRect() {
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
    let visibleCanvasFrame = attachmentContentView.convert(effectiveLiveRect, to: viewportCanvasView)

    canvasView?.setViewport(
      visibleContentRect: effectiveLiveRect,
      visibleCanvasFrame: visibleCanvasFrame,
      zoomScale: scrollView.zoomScale
    )

  }

  private func contentPoint(fromViewportPoint point: CGPoint) -> CGPoint {
    viewportGestureView.convert(point, to: attachmentContentView)
  }

  private func publishMetrics() {
    let activeStamps = canvasView?.activeStampCount ?? 0
    let committedStamps = canvasView?.committedStampCount ?? 0
    onMetricsChange?(
      MetalBrushSandboxMetrics(
        zoomScale: Double(scrollView.zoomScale),
        stampCount: activeStamps + committedStamps,
        strokeCount: canvasView?.strokeCount ?? 0,
        framesPerSecond: canvasView?.framesPerSecond ?? 0
      )
    )
  }
}

private extension EditingStack.Edit.LocalAdjustmentEffect {
  enum SandboxEffectIdentity: Equatable {
    case blur
    case exposure
  }

  var usesSandboxShaderCompositeExposure: Bool {
    switch self {
    case .gaussianBlur:
      return false
    case .exposure:
      return true
    }
  }

  var sandboxEffectIdentity: SandboxEffectIdentity {
    switch self {
    case .gaussianBlur:
      return .blur
    case .exposure:
      return .exposure
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
