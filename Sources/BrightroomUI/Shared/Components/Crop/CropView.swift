//
// Copyright (c) 2021 Muukii <muukii.app@gmail.com>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import SwiftUI
import UIKit
import MetalKit

import BrightroomEngine

/// A UIKit crop surface that previews crop geometry and hosts tool-mode canvas
/// interactions.
///
/// Based on the editing vision in `docs/vision-of-editing.md`, this view treats
/// tool modes as Features that happen before the final crop:
///
/// ```text
/// Source -> Tool Features -> Final Crop -> Output
/// ```
///
/// Crop mode edits the final crop frame while showing the result of earlier
/// Tool Features. Tool modes, such as blur masking, inspect the final cropped
/// output while authoring parameters that still belong to the pre-final-crop
/// image domain. In practice, this means Tool navigation must not mutate crop
/// geometry, and Tool strokes cross domains when they are displayed or saved.
///
/// Crop adjustment is available in two ways:
/// - Scrolling the image.
/// - Panning the guide.
///
/// - TODO:
///   - Implicit animations occurs in first time load with remote image.
final class CropView: UIView {

  typealias AdjustmentKind = SwiftUICropView.AdjustmentKind
  typealias StateSnapshot = SwiftUICropView.StateSnapshot

  private struct State {

    var proposedCrop: EditingCrop?

    var frame: CGRect = .zero

    var adjustmentKind: AdjustmentKind = []

    /// Returns aspect ratio. Would not be affected by rotation.
    var preferredAspectRatio: PixelAspectRatio?

    var snapshot: StateSnapshot {
      .init(
        proposedCrop: proposedCrop,
        frame: frame,
        adjustmentKind: adjustmentKind,
        preferredAspectRatio: preferredAspectRatio
      )
    }
  }

  private enum ScrollViewAdjustmentKind {
    case drag
    case zoom
  }

  private struct ScrollViewAdjustmentSession {
    let kind: ScrollViewAdjustmentKind
    let baselineCrop: EditingCrop
  }

  private typealias CanvasStrokeCommitHandler = (
    EditingCanvasStrokeRecord,
    @escaping () -> Void
  ) -> Void

  private enum ViewportRenderingSurface {
    case crop
    case tool
  }

  /// Holds the display-link lifecycle for a surface viewport.
  ///
  /// The state object is retained by the surface, while the display link
  /// targets this object rather than `CropView` to avoid a run-loop retain cycle
  /// against the whole crop view.
  private final class ViewportRenderingState: NSObject {
    weak var owner: CropView?
    let surface: ViewportRenderingSurface
    var displayLink: CADisplayLink?
    var stopWorkItem: DispatchWorkItem?

    var isRunning: Bool {
      displayLink != nil
    }

    init(surface: ViewportRenderingSurface) {
      self.surface = surface
    }

    func begin(preferredFramesPerSecond: Int) {
      guard displayLink == nil else {
        return
      }

      let displayLink = CADisplayLink(
        target: self,
        selector: #selector(displayLinkDidTick(_:))
      )
      displayLink.preferredFramesPerSecond = preferredFramesPerSecond
      displayLink.add(to: .main, forMode: .common)
      self.displayLink = displayLink
    }

    func invalidate() {
      stopWorkItem?.cancel()
      stopWorkItem = nil
      displayLink?.invalidate()
      displayLink = nil
    }

    deinit {
      invalidate()
    }

    @objc private func displayLinkDidTick(_ displayLink: CADisplayLink) {
      guard let owner else {
        invalidate()
        return
      }

      owner.viewportRenderingDisplayLinkDidTick(displayLink, surface: surface)
    }
  }

  /// Owns the shared UIKit view graph that hosts the crop and tool surfaces.
  ///
  /// The platter is shared because crop and tool scroll views are siblings under
  /// the same clipping and mask plane. It should not be owned by either surface.
  private final class SurfaceHost {
    let platterView = UIView()
    let backdropView = UIView()
  }

  /// Owns the scroll, image platter, and Metal canvas state used while
  /// adjusting the final Crop Feature.
  ///
  /// This is a reference type because UIKit may re-enter scroll-view delegate
  /// callbacks while the surface is updating its views and layers.
  private final class CropSurface: NSObject, UIScrollViewDelegate {
    let scrollView = _ScrollView()
    let imagePlatterView = ImagePlatterView()
    var canvasView: _EditingCanvasMTKView?
    var canvasSize: CGSize?
    var currentCanvasInputKey: CanvasInputKey?
    let viewportRendering = ViewportRenderingState(surface: .crop)

    /// Called when the crop scroll view changes zoom scale.
    var onDidZoom: (() -> Void)?
    /// Called when the crop scroll view changes content offset.
    var onDidScroll: (() -> Void)?
    /// Called when the user starts dragging the crop viewport.
    var onWillBeginDragging: (() -> Void)?
    /// Called when the user starts pinching the crop viewport.
    var onWillBeginZooming: (() -> Void)?
    /// Called when crop viewport dragging ends.
    var onDidEndDragging: ((Bool) -> Void)?
    /// Called when crop viewport pinch zooming ends.
    var onDidEndZooming: ((CGFloat) -> Void)?
    /// Called when crop viewport deceleration ends.
    var onDidEndDecelerating: (() -> Void)?

    override init() {
      super.init()
      scrollView.delegate = self
    }

    var hasCanvasView: Bool {
      canvasView != nil
    }

    var isInteractiveZoomGestureActive: Bool {
      switch scrollView.pinchGestureRecognizer?.state {
      case .began, .changed:
        return true
      case .cancelled, .ended, .failed, .possible, .none:
        return false
      @unknown default:
        return false
      }
    }

    var isZoomInteractionActive: Bool {
      if scrollView.isZooming || scrollView.isZoomBouncing {
        return true
      }

      switch scrollView.pinchGestureRecognizer?.state {
      case .began, .changed:
        return true
      case .cancelled, .ended, .failed, .possible, .none:
        return false
      @unknown default:
        return false
      }
    }

    var isViewportPresentationSettled: Bool {
      let tolerance: CGFloat = 0.5

      let isScrollBoundsSettled = scrollView.layer.presentation()?.bounds
        .isNearlyEqual(to: scrollView.bounds, tolerance: tolerance) ?? true
      let isPlatterFrameSettled = imagePlatterView.layer.presentation()?.frame
        .isNearlyEqual(to: imagePlatterView.frame, tolerance: tolerance) ?? true

      return isScrollBoundsSettled && isPlatterFrameSettled
    }

    @discardableResult
    func ensureCanvasView(
      canvasSize: CGSize,
      brush: EditingCanvasBrush,
      smoothing: EditingCanvasStrokeSmoothingConfiguration,
      onStrokeCommit: @escaping CanvasStrokeCommitHandler
    ) -> _EditingCanvasMTKView? {
      if let canvasView, self.canvasSize == canvasSize {
        return canvasView
      }

      removeCanvasView()

      guard
        canvasSize.width > 0,
        canvasSize.height > 0,
        let device = MTLCreateSystemDefaultDevice()
      else {
        return nil
      }

      let view = _EditingCanvasMTKView(canvasSize: canvasSize, device: device)
      view.isUserInteractionEnabled = false
      view.isHidden = true
      view.setViewportCachedSourceEnabled(true)
      view.configure(brush: brush, smoothing: smoothing)
      view.onStrokeCommit = onStrokeCommit
      scrollView.insertSubview(view, belowSubview: imagePlatterView)
      canvasView = view
      self.canvasSize = canvasSize
      return view
    }

    func removeCanvasView() {
      viewportRendering.invalidate()
      canvasView?.removeFromSuperview()
      canvasView = nil
      canvasSize = nil
      currentCanvasInputKey = nil
    }

    func hideCanvasView() {
      canvasView?.isHidden = true
    }

    func configureCanvas(
      brush: EditingCanvasBrush,
      smoothing: EditingCanvasStrokeSmoothingConfiguration
    ) {
      canvasView?.configure(brush: brush, smoothing: smoothing)
    }

    func setCommittedStrokes(_ records: [EditingCanvasStrokeRecord]) {
      canvasView?.setCommittedStrokes(records)
    }

    func updateCanvas(
      loadedState: EditingStack.Loaded,
      crop: EditingCrop,
      mode: EditingCanvasMode,
      committedStrokes: [EditingCanvasStrokeRecord]
    ) {
      guard crop.imageSize == canvasSize, let canvasView else {
        return
      }

      guard
        let images = EditingCanvasRenderImageFactory.makeRenderImages(
          loadedState: loadedState,
          canvasSize: crop.imageSize,
          mode: mode
        )
      else {
        return
      }

      canvasView.setRenderImages(images)
      canvasView.setCommittedStrokes(committedStrokes)
      canvasView.isHidden = false
    }

    func updateRenderedEditPreview(
      loadedState: EditingStack.Loaded,
      crop: EditingCrop
    ) {
      guard crop.imageSize == canvasSize, let canvasView else {
        return
      }

      let key = CanvasInputKey(loadedState: loadedState, crop: crop)
      guard currentCanvasInputKey != key || canvasView.hasRenderImages == false else {
        canvasView.isHidden = false
        return
      }

      let renderPlan = CanvasRenderPlan(
        localAdjustments: loadedState.currentEdit.localAdjustments
      )
      guard
        let images = EditingCanvasRenderImageFactory.makeRenderImages(
          loadedState: loadedState,
          canvasSize: crop.imageSize,
          mode: renderPlan.canvasMode
        )
      else {
        return
      }

      canvasView.setRenderImages(images)
      canvasView.setCommittedStrokes(renderPlan.committedStrokes)
      canvasView.isHidden = false
      currentCanvasInputKey = key
    }

    func applyViewport(
      _ viewport: CropDisplayViewport?,
      viewportProvider: _EditingCanvasMTKView.ViewportProvider? = nil
    ) {
      guard let canvasView else {
        return
      }

      guard let viewport else {
        canvasView.isHidden = true
        canvasView.setViewportProvider(nil, schedulesDisplay: false)
        return
      }

      canvasView.isHidden = false
      canvasView.frame = viewport.viewportFrameInScrollView
      canvasView.contentScaleFactor = viewport.contentScaleFactor
      if let viewportProvider {
        canvasView.setViewportProvider(viewportProvider)
      } else {
        canvasView.setViewportProvider(nil, schedulesDisplay: false)
        canvasView.setViewport(viewport.editingCanvasViewport)
      }
    }

    func applyMode(isActive: Bool) {
      if isActive == false {
        viewportRendering.invalidate()
      }
      scrollView.isScrollEnabled = isActive
      scrollView.pinchGestureRecognizer?.isEnabled = isActive
      scrollView.isHidden = !isActive
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
      imagePlatterView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
      onDidZoom?()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
      onDidScroll?()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
      onWillBeginDragging?()
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
      onWillBeginZooming?()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
      onDidEndDragging?(decelerate)
    }

    func scrollViewDidEndZooming(
      _ scrollView: UIScrollView,
      with view: UIView?,
      atScale scale: CGFloat
    ) {
      onDidEndZooming?(scale)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
      onDidEndDecelerating?()
    }

    func remainingScroll(
      guideRectInPlatter: CGRect,
      guideSize: CGSize,
      crop: EditingCrop
    ) -> UIEdgeInsets {
      let scale = Geometry.diagonalRatio(to: guideSize, from: guideRectInPlatter.size)
      let outbound = imagePlatterView.bounds

      let rawInsets = UIEdgeInsets(
        top: guideRectInPlatter.minY - outbound.minY,
        left: guideRectInPlatter.minX - outbound.minX,
        bottom: outbound.maxY - guideRectInPlatter.maxY,
        right: outbound.maxX - guideRectInPlatter.maxX
      )
      let sourceInsets = rawInsets.multiplied(scale)

#if false
      let maxRectInPlatter = imagePlatterView.convert(
        guideRectInPlatter.inset(by: rawInsets.inversed()),
        to: imagePlatterView
      )

      let path = UIBezierPath()
      path.append(.init(rect: guideRectInPlatter))
      path.append(.init(rect: maxRectInPlatter))

      imagePlatterView._debug_setPath(path: path)
#endif

      var patternAngleDegree = crop.aggregatedRotation.degrees.truncatingRemainder(dividingBy: 360)
      if patternAngleDegree > 0 {
        patternAngleDegree -= 360
      }

      switch patternAngleDegree {
      case 0:
        return sourceInsets
      case -90:
        return .init(
          top: sourceInsets.right,
          left: sourceInsets.top,
          bottom: sourceInsets.left,
          right: sourceInsets.bottom
        )
      case -180:
        return .init(
          top: sourceInsets.bottom,
          left: sourceInsets.right,
          bottom: sourceInsets.top,
          right: sourceInsets.left
        )
      case -270:
        return .init(
          top: sourceInsets.left,
          left: sourceInsets.bottom,
          bottom: sourceInsets.right,
          right: sourceInsets.top
        )
      case -90..<0:
        return .init(
          top: min(sourceInsets.top, sourceInsets.right),
          left: min(sourceInsets.top, sourceInsets.left),
          bottom: min(sourceInsets.bottom, sourceInsets.left),
          right: min(sourceInsets.bottom, sourceInsets.right)
        )
      case -180..<(-90):
        return .init(
          top: min(sourceInsets.bottom, sourceInsets.right),
          left: min(sourceInsets.top, sourceInsets.right),
          bottom: min(sourceInsets.top, sourceInsets.left),
          right: min(sourceInsets.bottom, sourceInsets.left)
        )
      case -270..<(-180):
        return .init(
          top: min(sourceInsets.bottom, sourceInsets.left),
          left: min(sourceInsets.bottom, sourceInsets.right),
          bottom: min(sourceInsets.top, sourceInsets.right),
          right: min(sourceInsets.top, sourceInsets.left)
        )
      case -360..<(-270):
        return .init(
          top: min(sourceInsets.top, sourceInsets.left),
          left: min(sourceInsets.bottom, sourceInsets.left),
          bottom: min(sourceInsets.bottom, sourceInsets.right),
          right: min(sourceInsets.top, sourceInsets.right)
        )
      default:
        return sourceInsets
      }
    }
  }

  /// Owns the scroll and Metal canvas state used while adjusting Tool Features
  /// that are evaluated before the final Crop Feature.
  ///
  /// The Tool surface navigates the crop-output image. Drawing gestures arrive
  /// in that crop-output coordinate space, then `CropView` maps the committed
  /// stroke back into the pre-crop Feature domain before saving it.
  private final class ToolSurface: NSObject, UIScrollViewDelegate {
    let scrollView = _ScrollView()
    let contentView: UIView = {
      let view = UIView()
      view.backgroundColor = .clear
      view.isOpaque = false
      view.accessibilityIdentifier = "toolSurfaceContentView"
      return view
    }()
    let drawingGestureRecognizer = _EditingCanvasDrawingGestureRecognizer(target: nil, action: nil)
    var canvasView: _EditingCanvasMTKView?
    var canvasSize: CGSize?
    var crop: EditingCrop?
    var outputGeometry: EditingCanvasCropOutputGeometry?
    let viewportRendering = ViewportRenderingState(surface: .tool)

    /// Called when the tool scroll view changes zoom scale.
    var onDidZoom: (() -> Void)?
    /// Called when the tool scroll view changes content offset.
    var onDidScroll: (() -> Void)?
    /// Called when the user starts panning the tool viewport.
    var onWillBeginDragging: (() -> Void)?
    /// Called when the user starts pinching the tool viewport.
    var onWillBeginZooming: (() -> Void)?
    /// Called when tool viewport dragging ends.
    var onDidEndDragging: (() -> Void)?
    /// Called when tool viewport pinch zooming ends.
    var onDidEndZooming: (() -> Void)?
    /// Called when tool viewport deceleration ends.
    var onDidEndDecelerating: (() -> Void)?

    override init() {
      super.init()
      scrollView.delegate = self
    }

    var hasCanvasView: Bool {
      canvasView != nil
    }

    var isInteractiveZoomGestureActive: Bool {
      switch scrollView.pinchGestureRecognizer?.state {
      case .began, .changed:
        return true
      case .cancelled, .ended, .failed, .possible, .none:
        return false
      @unknown default:
        return false
      }
    }

    var isZoomInteractionActive: Bool {
      if scrollView.isZooming || scrollView.isZoomBouncing {
        return true
      }

      switch scrollView.pinchGestureRecognizer?.state {
      case .began, .changed:
        return true
      case .cancelled, .ended, .failed, .possible, .none:
        return false
      @unknown default:
        return false
      }
    }

    var isZoomBouncing: Bool {
      scrollView.isZoomBouncing
    }

    var isViewportPresentationSettled: Bool {
      let tolerance: CGFloat = 0.5

      let isScrollBoundsSettled = scrollView.layer.presentation()?.bounds
        .isNearlyEqual(to: scrollView.bounds, tolerance: tolerance) ?? true
      let isContentFrameSettled = contentView.layer.presentation()?.frame
        .isNearlyEqual(to: contentView.frame, tolerance: tolerance) ?? true

      return isScrollBoundsSettled && isContentFrameSettled
    }

    @discardableResult
    func ensureCanvasView(
      canvasSize: CGSize,
      brush: EditingCanvasBrush,
      smoothing: EditingCanvasStrokeSmoothingConfiguration,
      onStrokeCommit: @escaping CanvasStrokeCommitHandler
    ) -> _EditingCanvasMTKView? {
      if let canvasView, self.canvasSize == canvasSize {
        return canvasView
      }

      removeCanvasView()

      guard
        canvasSize.width > 0,
        canvasSize.height > 0,
        let device = MTLCreateSystemDefaultDevice()
      else {
        return nil
      }

      let view = _EditingCanvasMTKView(canvasSize: canvasSize, device: device)
      view.isUserInteractionEnabled = false
      view.isHidden = true
      view.setViewportCachedSourceEnabled(true)
      view.configure(brush: brush, smoothing: smoothing)
      view.onStrokeCommit = onStrokeCommit
      scrollView.insertSubview(view, belowSubview: contentView)
      canvasView = view
      self.canvasSize = canvasSize
      return view
    }

    func removeCanvasView() {
      viewportRendering.invalidate()
      canvasView?.layer.mask = nil
      canvasView?.removeFromSuperview()
      canvasView = nil
      canvasSize = nil
      crop = nil
      outputGeometry = nil
    }

    func hideCanvasView() {
      canvasView?.isHidden = true
    }

    func configureCanvas(
      brush: EditingCanvasBrush,
      smoothing: EditingCanvasStrokeSmoothingConfiguration
    ) {
      canvasView?.configure(brush: brush, smoothing: smoothing)
    }

    func beginStroke(at imagePoint: CGPoint) {
      canvasView?.beginStroke(at: imagePoint)
    }

    func appendStroke(points imagePoints: [CGPoint]) {
      canvasView?.appendStroke(points: imagePoints)
    }

    func endStroke(at imagePoint: CGPoint) {
      canvasView?.endStroke(at: imagePoint)
    }

    func cancelStroke() {
      canvasView?.cancelStroke()
    }

    func setCommittedStrokes(_ records: [EditingCanvasStrokeRecord]) {
      canvasView?.setCommittedStrokes(records)
    }

    func updateCanvas(
      loadedState: EditingStack.Loaded,
      geometry: EditingCanvasCropOutputGeometry,
      mode: EditingCanvasMode,
      committedStrokes: [EditingCanvasStrokeRecord]
    ) {
      guard geometry.outputSize == canvasSize, let canvasView else {
        return
      }
      outputGeometry = geometry

      guard
        let images = EditingCanvasRenderImageFactory.makeCropOutputRenderImages(
          loadedState: loadedState,
          geometry: geometry,
          mode: mode
        )
      else {
        return
      }

      canvasView.setRenderImages(images)
      canvasView.setCommittedStrokes(committedStrokes)
      canvasView.isHidden = false
    }

    func applyViewport(
      _ viewport: CropDisplayViewport?,
      viewportProvider: _EditingCanvasMTKView.ViewportProvider? = nil
    ) {
      guard let canvasView else {
        return
      }

      guard let viewport else {
        canvasView.isHidden = true
        canvasView.setViewportProvider(nil, schedulesDisplay: false)
        return
      }

      canvasView.isHidden = false
      canvasView.frame = viewport.viewportFrameInScrollView
      canvasView.contentScaleFactor = viewport.contentScaleFactor
      if let viewportProvider {
        canvasView.setViewportProvider(viewportProvider)
      } else {
        canvasView.setViewportProvider(nil, schedulesDisplay: false)
        canvasView.setViewport(viewport.editingCanvasViewport)
      }
    }

    func applyMode(
      isActive: Bool,
      isDrawingEnabled: Bool
    ) {
      if isActive == false {
        viewportRendering.invalidate()
      }
      scrollView.isHidden = !isActive
      scrollView.isScrollEnabled = isActive
      scrollView.pinchGestureRecognizer?.isEnabled = isActive
      scrollView.panGestureRecognizer.minimumNumberOfTouches = isDrawingEnabled ? 2 : 1
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
      contentView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
      onDidZoom?()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
      onDidScroll?()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
      onWillBeginDragging?()
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
      onWillBeginZooming?()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
      onDidEndDragging?()
    }

    func scrollViewDidEndZooming(
      _ scrollView: UIScrollView,
      with view: UIView?,
      atScale scale: CGFloat
    ) {
      onDidEndZooming?()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
      onDidEndDecelerating?()
    }

    /// Synchronizes the scrollable content size with the current zoomed
    /// crop-output image.
    ///
    /// This updates the scroll range without changing centering insets, so it
    /// can run while UIKit is animating zoom bounce-back.
    func synchronizeZoomedContentSize() {
      scrollView.contentSize = zoomedContentSize
    }

    /// Centers the crop-output image when the zoomed content is smaller than
    /// the Tool viewport. Tool mode presents the crop output as an image, so
    /// empty space belongs around that image rather than inside the image.
    func centerContentInViewport() {
      synchronizeZoomedContentSize()
      let contentSize = scrollView.contentSize
      let horizontalInset = max((scrollView.bounds.width - contentSize.width) / 2, 0)
      let verticalInset = max((scrollView.bounds.height - contentSize.height) / 2, 0)
      scrollView.contentInset = UIEdgeInsets(
        top: verticalInset,
        left: horizontalInset,
        bottom: verticalInset,
        right: horizontalInset
      )
    }

    var zoomedContentSize: CGSize {
      let contentSize = outputGeometry?.outputSize ?? contentView.frame.size
      return CGSize(
        width: contentSize.width * scrollView.zoomScale,
        height: contentSize.height * scrollView.zoomScale
      )
    }

  }

  /**
   A view that covers the area out of cropping extent.
   */
  private(set) weak var cropOutsideOverlay: UIView?

  private var state = State()

  /**
   A Boolean value that indicates whether the guide is interactive.
   If false, cropping adjustment is available only way from scrolling image-view.
   */
  var isGuideInteractionEnabled: Bool {
    get {
      guideView.isUserInteractionEnabled
    }
    set {
      self.guideView.isUserInteractionEnabled = newValue
    }
  }

  /**
   Clips ScrollView to guide view.
   */
  var clipsToGuide: Bool = false {
    didSet {
      updateCropLayout()
    }
  }

  var areAnimationsEnabled: Bool = true

  var isZoomEnabled: Bool = true {
    didSet {
      updateCropLayout()
    }
  }

  var isScrollEnabled: Bool {
    get {
      cropSurface.scrollView.isScrollEnabled
    }
    set {
      cropSurface.scrollView.isScrollEnabled = newValue
    }
  }

  var displayMode: CropViewDisplayMode = .renderedEditPreview {
    didSet {
      guard displayMode != oldValue else {
        return
      }

      guard state.proposedCrop != nil else {
        return
      }

      updateCurrentEditingStackDisplay()
    }
  }

  private var allowsToolViewingRenderedEditPreview: Bool {
    switch displayMode {
    case .cropInteractionImage:
      return false
    case .renderedEditPreview:
      return true
    }
  }

  let editingStack: EditingStack

  #if DEBUG
  private let _debug_shapeLayer: CAShapeLayer = {
    let layer = CAShapeLayer()
    layer.strokeColor = UIColor.red.cgColor
    layer.fillColor = UIColor.clear.cgColor
    layer.lineWidth = 2
    return layer
  }()
  #endif

  private let surfaceHost = SurfaceHost()
  private let cropSurface = CropSurface()
  private let toolSurface = ToolSurface()

  private var surfaceMode: CropViewSurfaceMode = .crop
  private var canvasBrush: EditingCanvasBrush = .init()
  private var canvasStrokeSmoothing: EditingCanvasStrokeSmoothingConfiguration = .init()
  private var editingCanvasLocalAdjustmentLayerID: UUID?
  /// True while an external control streams straighten angle changes before
  /// committing the resulting crop extent.
  ///
  /// Streaming straighten updates mutate the crop scroll transform without
  /// animation. During that phase, viewport conversion should read model layers
  /// so Metal rendering does not chase stale presentation-layer geometry.
  private var isStreamingAdjustmentAngle = false

  private var hasSetupScrollViewCompleted = false

  /**
   a guide view that displayed on guide container view.
   */
  private lazy var guideView = _InteractiveCropGuideView(
    containerView: self,
    insetOfGuideFlexibility: contentInset
  )

  private let guideMaximumView: UIView = {
    let view = UIView()
    view.backgroundColor = .clear
    view.isUserInteractionEnabled = false
    view.accessibilityIdentifier = "maximumView"
    return view
  }()

  // for now, for debugging
  private let guideShadowingView: UIView = {
    let view = UIView()
    //    #if DEBUG
    //    view.backgroundColor = .systemYellow.withAlphaComponent(0.5)
    //    #endif
    view.isUserInteractionEnabled = false
    view.accessibilityIdentifier = "guideShadowingView"
    return view
  }()

  private let guideBackdropView: UIView = {
    let view = UIView()
    view.backgroundColor = .clear
    view.isUserInteractionEnabled = false
    view.accessibilityIdentifier = "guideBackdropView"
    return view
  }()

  private let guideOutsideContainerView: UIView = {
    let view = UIView()
    view.backgroundColor = .clear
    view.isUserInteractionEnabled = false
    view.accessibilityIdentifier = "guideOutsideContainerView"
    return view
  }()

  /// A throttling timer to apply guide changed event.
  ///
  /// This's waiting for Combine availability in minimum iOS Version.
  private let debounce = _BrightroomDebounce(interval: 0.8)

  private let scrollViewSettleDebounce = _BrightroomDebounce(interval: 0.2)

  private let contentInset: UIEdgeInsets

  private var scrollViewAdjustmentSession: ScrollViewAdjustmentSession?

  private var scrollViewAdjustmentKind: ScrollViewAdjustmentKind? {
    scrollViewAdjustmentSession?.kind
  }

  private var stateHandler: @MainActor (StateSnapshot) -> Void = { _ in }

  var isAutoApplyEditingStackEnabled = false

  private var lastLaidOutCrop: EditingCrop?

  // MARK: - Initializers

  /**
   Creates an instance for using as standalone.

   This initializer offers us to get cropping function without detailed setup.
   To get a result image, call `renderImage()`.
   */
  convenience init(
    image: UIImage,
    contentInset: UIEdgeInsets = .init(top: 20, left: 20, bottom: 20, right: 20)
  ) throws {
    self.init(
      editingStack: .init(
        imageProvider: .init(image: image)
      ),
      contentInset: contentInset
    )
  }

  init(
    editingStack: EditingStack,
    contentInset: UIEdgeInsets = .init(top: 20, left: 20, bottom: 20, right: 20)
  ) {
    _pixeleditor_ensureMainThread()

    self.editingStack = editingStack
    self.contentInset = contentInset

    super.init(frame: .zero)

    identifiers: do {
      accessibilityIdentifier = "CropView"
      surfaceHost.platterView.accessibilityIdentifier = "CropView.surfaceHost.platterView"
      surfaceHost.backdropView.accessibilityIdentifier = "scrollBackdropView"
      cropSurface.scrollView.accessibilityIdentifier = "CropView.cropSurface.scrollView"
      cropSurface.imagePlatterView.accessibilityIdentifier = "CropView.cropSurface.imagePlatterView"
      toolSurface.scrollView.accessibilityIdentifier = "CropView.toolSurface.scrollView"
      toolSurface.contentView.accessibilityIdentifier = "CropView.toolSurface.contentView"
    }

    clipsToBounds = false

    addSubview(surfaceHost.platterView)
    surfaceHost.platterView.addSubview(surfaceHost.backdropView)
    surfaceHost.platterView.addSubview(cropSurface.scrollView)
    surfaceHost.platterView.addSubview(toolSurface.scrollView)

    addSubview(guideOutsideContainerView)
    addSubview(guideMaximumView)
    addSubview(guideShadowingView)
    addSubview(guideBackdropView)
    addSubview(guideView)

    toolDrawingGesture: do {
      toolSurface.drawingGestureRecognizer.delegate = self
      toolSurface.drawingGestureRecognizer.isEnabled = false
      toolSurface.drawingGestureRecognizer.onBegin = { [weak self] point in
        guard let self else { return }
        self.toolSurface.beginStroke(at: point)
      }
      toolSurface.drawingGestureRecognizer.onMove = { [weak self] points in
        guard let self else { return }
        self.toolSurface.appendStroke(points: points)
      }
      toolSurface.drawingGestureRecognizer.onEnd = { [weak self] point in
        guard let self else { return }
        self.toolSurface.endStroke(at: point)
      }
      toolSurface.drawingGestureRecognizer.onCancel = { [weak self] in
        self?.toolSurface.cancelStroke()
      }
    }

    cropSurface.scrollView.addSubview(cropSurface.imagePlatterView)

    toolSurface.contentView.isUserInteractionEnabled = true
    toolSurface.scrollView.isHidden = true
    toolSurface.scrollView.addSubview(toolSurface.contentView)
    toolSurface.contentView.addGestureRecognizer(toolSurface.drawingGestureRecognizer)

    if #available(iOS 26.0, *) {
      cropSurface.scrollView.topEdgeEffect.isHidden = true
      cropSurface.scrollView.bottomEdgeEffect.isHidden = true
      cropSurface.scrollView.leftEdgeEffect.isHidden = true
      cropSurface.scrollView.rightEdgeEffect.isHidden = true
      toolSurface.scrollView.topEdgeEffect.isHidden = true
      toolSurface.scrollView.bottomEdgeEffect.isHidden = true
      toolSurface.scrollView.leftEdgeEffect.isHidden = true
      toolSurface.scrollView.rightEdgeEffect.isHidden = true
    }

    viewportRenderingOwners: do {
      cropSurface.viewportRendering.owner = self
      toolSurface.viewportRendering.owner = self
    }

    scrollEventHandlers: do {
      cropSurface.onDidZoom = { [weak self] in
        guard let self else { return }
        self.debugLogScrollViewAdjustment("did-zoom")
        self.updateCropViewportDuringScrollInteraction()

        self.debounce.on { [weak self] in
          guard let self else { return }
          guard self.surfaceMode == .crop else { return }

          self.updateCropLayout()
        }
      }
      cropSurface.onDidScroll = { [weak self] in
        guard let self else { return }
        self.debugLogScrollViewAdjustment("did-scroll")
        if self.isZoomInteractionActive || self.cropSurface.viewportRendering.isRunning {
          self.updateCropViewportDuringScrollInteraction()
        } else {
          self.updateCropDisplayViewport()
        }

        self.debounce.on { [weak self] in
          guard let self else { return }
          guard self.surfaceMode == .crop else { return }
          guard self.cropSurface.scrollView.isTracking == false else { return }

          self.updateCropLayout()
        }
      }
      cropSurface.onWillBeginDragging = { [weak self] in
        guard let self else { return }
        self.debugLogScrollViewAdjustment("drag-begin")
        self.beginScrollViewAdjustment(.drag)
      }
      cropSurface.onWillBeginZooming = { [weak self] in
        guard let self else { return }
        self.debugLogScrollViewAdjustment("zoom-begin")
        self.stopViewportRendering(for: .crop, appliesViewport: false)
        self.beginScrollViewAdjustment(.zoom)
      }
      cropSurface.onDidEndDragging = { [weak self] decelerate in
        guard let self else { return }
        self.debugLogScrollViewAdjustment("drag-end decelerate:\(decelerate)")

        if !decelerate {
          self.endScrollViewAdjustment(.drag)
        }
      }
      cropSurface.onDidEndZooming = { [weak self] scale in
        guard let self else { return }
        self.debugLogScrollViewAdjustment("zoom-end scale:\(scale)")
        self.endScrollViewAdjustment(.zoom)
        self.updateCropViewportDuringScrollInteraction()
      }
      cropSurface.onDidEndDecelerating = { [weak self] in
        guard let self else { return }
        self.debugLogScrollViewAdjustment("deceleration-end")
        self.endScrollViewAdjustment(.drag)
      }

      toolSurface.onDidZoom = { [weak self] in
        guard let self else { return }
        if self.toolSurface.isZoomBouncing {
          self.toolSurface.synchronizeZoomedContentSize()
        } else {
          self.toolSurface.centerContentInViewport()
        }
        self.updateToolViewportDuringScrollInteraction()
      }
      toolSurface.onDidScroll = { [weak self] in
        self?.updateToolViewportDuringScrollInteraction()
      }
      toolSurface.onWillBeginDragging = { [weak self] in
        self?.beginViewportRendering(for: .tool)
      }
      toolSurface.onWillBeginZooming = { [weak self] in
        self?.stopViewportRendering(for: .tool, appliesViewport: false)
      }
      toolSurface.onDidEndDragging = { [weak self] in
        self?.updateToolCropDisplayViewport()
      }
      toolSurface.onDidEndZooming = { [weak self] in
        guard let self else { return }
        self.updateToolViewportDuringScrollInteraction()
      }
      toolSurface.onDidEndDecelerating = { [weak self] in
        self?.updateToolCropDisplayViewport()
      }
    }

    guideView.willChange = { [weak self] in
      guard let self = self else { return }
      self.willChangeGuideView()
    }

    guideView.didChange = { [weak self] in
      guard let self = self else { return }
      self.didChangeGuideViewWithDelay()
    }

    guideView.didUpdateAdjustmentKind = { [weak self] kind in
      guard let self else { return }
      self.state.adjustmentKind = kind
      self.emitStateSnapshot()
    }

    // apply defaultAppearance
    do {
      setCropInsideOverlay(CropView.CropInsideOverlayRuleOfThirdsView())
      setCropOutsideOverlay(CropView.CropOutsideOverlayBlurredView())
    }

  }

  @available(*, unavailable)
  public required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    cropSurface.viewportRendering.invalidate()
    toolSurface.viewportRendering.invalidate()
  }

  // MARK: - Functions

  func setStateHandler(_ handler: @escaping @MainActor (StateSnapshot) -> Void) {
    self.stateHandler = handler
  }

  func load(image _: CGImage, crop: EditingCrop) {
    _pixeleditor_ensureMainThread()

    prepareForCropIfNeeded(crop)
    setProposedCrop(crop, forcesLayout: true)
    updateCurrentEditingStackDisplay()
  }

  func loadCurrentEditingStackState() {
    let loadedState = editingStack.requireLoadedStateForLoadedUIView()
    load(crop: loadedState.currentEdit.crop)
    updateDisplay(loadedState: loadedState)
  }

  func updateCurrentEditingStackDisplay() {
    guard let loadedState = editingStack.loadedState else {
      return
    }

    if state.proposedCrop == nil || state.proposedCrop?.imageSize != loadedState.currentEdit.crop.imageSize {
      load(crop: loadedState.currentEdit.crop)
    }

    updateDisplay(loadedState: loadedState)
  }

  /**
   Renders an image according to the editing.

   - Attension: This operation can be run background-thread.
   */
  func renderImage() throws -> BrightRoomImageRenderer.Rendered? {
    applyEditingStack()
    return try editingStack.makeRenderer().render()
  }

  /**
   Applies the current state to the EditingStack.
   */
  func applyEditingStack() {
    guard let crop = state.proposedCrop else {
      EditorLog.error(.cropView, "EditingStack has not completed loading.")
      return
    }
    applyCropToEditingStackIfRenderingChanged(crop)
  }

  func resetCrop() {
    _pixeleditor_ensureMainThread()

    debounce.cancel()
    scrollViewSettleDebounce.cancel()
    scrollViewAdjustmentSession = nil
    state.adjustmentKind = []
    state.preferredAspectRatio = nil
    guideView.setLockedAspectRatio(nil)

    if let crop = state.proposedCrop {
      setProposedCrop(crop.makeInitial(), previousCrop: crop, forcesLayout: true)
    }

    emitStateSnapshot()
  }

  func setRotation(_ rotation: EditingCrop.Rotation) {
    _pixeleditor_ensureMainThread()

    guard var crop = state.proposedCrop, crop.rotation != rotation else {
      return
    }

    crop.updateCropExtent(
      crop.cropExtent.rotated((crop.rotation.angle - rotation.angle).radians)
    )
    crop.rotation = rotation
    setProposedCrop(crop)
  }

  func rotateClockwise() {
    _pixeleditor_ensureMainThread()

    guard var crop = state.proposedCrop else {
      return
    }

    let nextRotation = crop.rotation.next()
    crop.updateCropExtent(
      crop.cropExtent.rotated((crop.rotation.angle - nextRotation.angle).radians)
    )
    crop.rotation = nextRotation

    if let preferredAspectRatio = state.preferredAspectRatio?.swapped() {
      state.preferredAspectRatio = preferredAspectRatio
      guideView.setLockedAspectRatio(preferredAspectRatio)
      crop.updateCropExtentIfNeeded(toFitAspectRatio: preferredAspectRatio)
    }

    setProposedCrop(crop, forcesLayout: true)
  }

  func setAdjustmentAngle(
    _ angle: EditingCrop.AdjustmentAngle,
    recordsCropExtent: Bool = true
  ) {
    guard var crop = state.proposedCrop, crop.adjustmentAngle != angle else {
      return
    }

    isStreamingAdjustmentAngle = recordsCropExtent == false
    crop.adjustmentAngle = angle
    setProposedCrop(crop, animatesLayout: false)

    if recordsCropExtent {
      record()
      isStreamingAdjustmentAngle = false
    }
  }

  func commitAdjustmentAngle(_ angle: EditingCrop.AdjustmentAngle) {
    setAdjustmentAngle(angle, recordsCropExtent: false)
    record()
    isStreamingAdjustmentAngle = false
    updateCropDisplayViewport()
  }

  func setCrop(_ crop: EditingCrop) {
    _pixeleditor_ensureMainThread()

    var crop = crop
    if let ratio = state.preferredAspectRatio {
      crop.updateCropExtentIfNeeded(toFitAspectRatio: ratio)
    }
    setProposedCrop(crop)
  }

  func setCroppingAspectRatio(_ ratio: PixelAspectRatio?) {
    _pixeleditor_ensureMainThread()

    guard state.preferredAspectRatio != ratio else {
      return
    }

    state.preferredAspectRatio = ratio
    var crop = state.proposedCrop
    if let ratio = ratio {
      crop?.updateCropExtentIfNeeded(toFitAspectRatio: ratio)
    } else {
      crop?.purgeAspectRatio()
    }
    if let crop {
      setProposedCrop(crop, forcesLayout: true)
    } else {
      updateCropLayout()
    }

    guideView.setLockedAspectRatio(ratio)
    emitStateSnapshot()
  }

  /**
   Displays a view as an overlay.
   e.g. grid view

   - Parameters:
   - view: In case of no needs to display overlay, pass nil.
   */
  func setCropInsideOverlay(_ view: CropInsideOverlayBase?) {
    _pixeleditor_ensureMainThread()

    guideView.setCropInsideOverlay(view)
  }

  func swapCropRectangleDirection() {
    guard var crop = state.proposedCrop else {
      return
    }

    crop.updateCropExtentIfNeeded(
      toFitAspectRatio: PixelAspectRatio(crop.cropExtent.size).swapped()
    )
    setProposedCrop(crop, forcesLayout: true)
  }

  /**
   Displays an overlay that covers the area out of cropping extent.
   Given view's frame would be adjusted automatically.

   - Attention: view's userIntereactionEnabled turns off
   - Parameters:
   - view: In case of no needs to display overlay, pass nil.
   */
  func setCropOutsideOverlay(_ view: CropOutsideOverlayBase?) {
    _pixeleditor_ensureMainThread()

    cropOutsideOverlay?.removeFromSuperview()

    guard let view = view else {
      // just removing
      return
    }

    cropOutsideOverlay = view
    view.isUserInteractionEnabled = false

    guideOutsideContainerView.addSubview(view)

    guideView.setCropOutsideOverlay(view)

    setNeedsLayout()
    layoutIfNeeded()
  }

}

// MARK: Internal

extension CropView {
  private func load(crop: EditingCrop) {
    prepareForCropIfNeeded(crop)
    setProposedCrop(crop, forcesLayout: true)
  }

  private func prepareForCropIfNeeded(_ crop: EditingCrop) {
    if state.proposedCrop?.imageSize != crop.imageSize {
      hasSetupScrollViewCompleted = false
      lastLaidOutCrop = nil
      cropSurface.removeCanvasView()
      toolSurface.removeCanvasView()
    }
  }

  private func updateDisplay(loadedState: EditingStack.Loaded) {
    guard let crop = state.proposedCrop else {
      return
    }

    func ensureToolCanvas(geometry: EditingCanvasCropOutputGeometry) -> Bool {
      cropSurface.hideCanvasView()
      return toolSurface.ensureCanvasView(
        canvasSize: geometry.outputSize,
        brush: canvasBrush,
        smoothing: canvasStrokeSmoothing,
        onStrokeCommit: { [weak self] record, completion in
          self?.commitCanvasStroke(record: record, completion: completion)
        }
      ) != nil
    }

    switch surfaceMode {
    case .crop:
      toolSurface.hideCanvasView()
      guard
        cropSurface.ensureCanvasView(
          canvasSize: crop.imageSize,
          brush: canvasBrush,
          smoothing: canvasStrokeSmoothing,
          onStrokeCommit: { [weak self] record, completion in
            self?.commitCanvasStroke(record: record, completion: completion)
          }
        ) != nil
      else {
        return
      }

      updateCanvasContent(loadedState: loadedState, crop: crop)
      updateCropDisplayViewport()

    case .viewing:
      guard
        let geometry = EditingCanvasCropOutputGeometry(crop: crop),
        ensureToolCanvas(geometry: geometry)
      else {
        return
      }

      let renderPlan = CanvasRenderPlan(
        localAdjustments: loadedState.currentEdit.localAdjustments,
        allowsRenderedEditPreview: allowsToolViewingRenderedEditPreview
      )
      toolSurface.updateCanvas(
        loadedState: loadedState,
        geometry: geometry,
        mode: renderPlan.canvasMode,
        committedStrokes: renderPlan.committedStrokes
      )
      updateToolCropDisplayViewport()

    case let .masking(effect):
      guard
        let geometry = EditingCanvasCropOutputGeometry(crop: crop),
        ensureToolCanvas(geometry: geometry)
      else {
        return
      }

      toolSurface.updateCanvas(
        loadedState: loadedState,
        geometry: geometry,
        mode: .localAdjustment(effect: effect),
        committedStrokes: currentToolCommittedStrokes(in: geometry)
      )
      updateToolCropDisplayViewport()
    }
  }

  private func updateCropDisplayViewport() {
    guard surfaceMode == .crop else {
      cropSurface.hideCanvasView()
      stopViewportRendering(for: .crop, appliesViewport: false)
      return
    }

    cropSurface.applyViewport(makeCropDisplayViewport())
  }

  private func updateToolCropDisplayViewport() {
    guard surfaceMode != .crop else {
      toolSurface.hideCanvasView()
      return
    }

    surfaceHost.platterView.layer.mask = nil
    toolSurface.applyViewport(makeToolCropDisplayViewport())
  }

  private struct CanvasInputKey: Equatable {
    var imageSize: CGSize
    var sourceExtent: CGRect
    var filters: EditingStack.Edit.Filters
    var localAdjustments: [EditingStack.Edit.LocalAdjustmentLayer]

    init(loadedState: EditingStack.Loaded, crop: EditingCrop) {
      let previewSourceImage = loadedState.editingSourceImage.removingExtentOffset()
      self.imageSize = crop.imageSize
      self.sourceExtent = previewSourceImage.extent
      self.filters = loadedState.currentEdit.filters
      self.localAdjustments = loadedState.currentEdit.localAdjustments
    }
  }

  // TODO: Consider to remove this
  private enum CanvasRenderPlan: Equatable {
    case viewportBase
    case singleLocalAdjustment(EditingStack.Edit.LocalAdjustmentLayer)
    case renderedEditPreview

    init(
      localAdjustments: [EditingStack.Edit.LocalAdjustmentLayer],
      allowsRenderedEditPreview: Bool = true
    ) {
      let activeLayers = localAdjustments.filter {
        $0.isEnabled && $0.effect.isActive && $0.mask.isEmpty == false
      }

      switch activeLayers.count {
      case 0:
        self = .viewportBase
      case 1:
        self = .singleLocalAdjustment(activeLayers[0])
      default:
        self = allowsRenderedEditPreview ? .renderedEditPreview : .viewportBase
      }
    }

    var canvasMode: EditingCanvasMode {
      switch self {
      case .viewportBase:
        return .viewportBase
      case let .singleLocalAdjustment(layer):
        return .localAdjustment(effect: layer.effect)
      case .renderedEditPreview:
        return .renderedEditPreview
      }
    }

    var committedStrokes: [EditingCanvasStrokeRecord] {
      switch self {
      case .viewportBase, .renderedEditPreview:
        return []
      case let .singleLocalAdjustment(layer):
        return layer.mask.strokes.map {
          EditingCanvasStrokeRecord(localAdjustmentStroke: $0)
        }
      }
    }
  }

  private func makeCropDisplayViewport() -> CropDisplayViewport? {
    guard let crop = state.proposedCrop else {
      return nil
    }

    let usesPresentationLayers = cropSurface.isInteractiveZoomGestureActive == false
      && isStreamingAdjustmentAngle == false
    let visibleViewportFrame = Self.currentLayerRect(
      bounds,
      from: self,
      to: cropSurface.scrollView,
      usesPresentationLayers: usesPresentationLayers
    )
      .standardized
    guard visibleViewportFrame.width > 0, visibleViewportFrame.height > 0 else {
      return nil
    }

    let renderFrame = Self.renderOverscanFrame(
      for: visibleViewportFrame,
      rotationRadians: crop.aggregatedRotation.radians
    )
    let platterBounds = CGRect(origin: .zero, size: cropSurface.imagePlatterView.bounds.size)
    let visiblePlatterRect = Self.currentLayerRect(
      renderFrame,
      from: cropSurface.scrollView,
      to: cropSurface.imagePlatterView,
      usesPresentationLayers: usesPresentationLayers
    )
      .standardized
      .intersection(platterBounds)

    guard visiblePlatterRect.isNull == false, visiblePlatterRect.isEmpty == false else {
      return nil
    }

    let imageBounds = CGRect(origin: .zero, size: crop.imageSize)
    let visibleImageRect = Self.platterRectToImageRect(visiblePlatterRect, crop: crop)
      .intersection(imageBounds)

    guard visibleImageRect.isNull == false, visibleImageRect.isEmpty == false else {
      return nil
    }

    let resolvedVisiblePlatterRect = Self.imageRectToPlatterRect(visibleImageRect, crop: crop)
    let resolvedVisibleScrollRect = Self.currentLayerRect(
      resolvedVisiblePlatterRect,
      from: cropSurface.imagePlatterView,
      to: cropSurface.scrollView,
      usesPresentationLayers: usesPresentationLayers
    )
      .standardized
    let visibleCanvasFrame = resolvedVisibleScrollRect.offsetBy(
      dx: -renderFrame.minX,
      dy: -renderFrame.minY
    )

    return .init(
      viewportFrameInScrollView: renderFrame,
      visibleContentRect: visibleImageRect,
      visibleCanvasFrame: visibleCanvasFrame,
      zoomScale: cropSurface.scrollView.zoomScale,
      contentScaleFactor: window?.screen.scale ?? UIScreen.main.scale
    )
  }

  private func makeToolCropDisplayViewport() -> CropDisplayViewport? {
    guard let geometry = toolSurface.outputGeometry else {
      return nil
    }

    let canvasFrame = toolSurface.scrollView.bounds
      .standardized
    guard canvasFrame.width > 0, canvasFrame.height > 0 else {
      return nil
    }

    let zoomScale = max(toolSurface.scrollView.zoomScale, 0.0001)
    let viewportOriginInOutput = CGPoint(
      x: (toolSurface.scrollView.contentOffset.x + toolSurface.scrollView.contentInset.left)
        / zoomScale,
      y: (toolSurface.scrollView.contentOffset.y + toolSurface.scrollView.contentInset.top)
        / zoomScale
    )
    let outputBounds = geometry.outputBounds
    let visibleOutputRect = CGRect(
      x: viewportOriginInOutput.x,
      y: viewportOriginInOutput.y,
      width: canvasFrame.width / zoomScale,
      height: canvasFrame.height / zoomScale
    )
      .intersection(outputBounds)

    guard visibleOutputRect.isNull == false, visibleOutputRect.isEmpty == false else {
      return nil
    }

    let visibleCanvasFrame = CGRect(
      x: toolSurface.scrollView.contentInset.left
        + visibleOutputRect.minX * zoomScale
        - (toolSurface.scrollView.contentOffset.x + toolSurface.scrollView.contentInset.left),
      y: toolSurface.scrollView.contentInset.top
        + visibleOutputRect.minY * zoomScale
        - (toolSurface.scrollView.contentOffset.y + toolSurface.scrollView.contentInset.top),
      width: visibleOutputRect.width * zoomScale,
      height: visibleOutputRect.height * zoomScale
    )

    return .init(
      viewportFrameInScrollView: canvasFrame,
      visibleContentRect: visibleOutputRect,
      visibleCanvasFrame: visibleCanvasFrame,
      zoomScale: zoomScale,
      contentScaleFactor: window?.screen.scale ?? UIScreen.main.scale
    )
  }

  // MARK: Static Helpers

  private static func renderOverscanFrame(
    for viewportFrame: CGRect,
    rotationRadians: CGFloat
  ) -> CGRect {
    let viewportFrame = viewportFrame.standardized
    guard viewportFrame.width > 0, viewportFrame.height > 0 else {
      return viewportFrame
    }

    let cosine = abs(CGFloat(cos(Double(rotationRadians))))
    let sine = abs(CGFloat(sin(Double(rotationRadians))))
    let rotatedWidth = viewportFrame.width * cosine + viewportFrame.height * sine
    let rotatedHeight = viewportFrame.width * sine + viewportFrame.height * cosine
    let renderSize = CGSize(
      width: max(viewportFrame.width, rotatedWidth),
      height: max(viewportFrame.height, rotatedHeight)
    )

    return CGRect(
      x: viewportFrame.midX - renderSize.width / 2,
      y: viewportFrame.midY - renderSize.height / 2,
      width: renderSize.width,
      height: renderSize.height
    )
  }

  private static func currentLayerRect(
    _ rect: CGRect,
    from sourceView: UIView,
    to targetView: UIView,
    usesPresentationLayers: Bool = true
  ) -> CGRect {
    let sourceLayer = sourceView.layer
    let targetLayer = targetView.layer

    if usesPresentationLayers,
       let sourcePresentationLayer = sourceLayer.presentation(),
       let targetPresentationLayer = targetLayer.presentation()
    {
      return targetPresentationLayer.convert(rect, from: sourcePresentationLayer)
    }

    return targetLayer.convert(rect, from: sourceLayer)
  }

  private static func platterRectToImageRect(
    _ rect: CGRect,
    crop: EditingCrop
  ) -> CGRect {
    let contentSize = crop.scrollViewContentSize()
    return rect.applying(
      CGAffineTransform(
        scaleX: crop.imageSize.width / max(contentSize.width, 0.0001),
        y: crop.imageSize.height / max(contentSize.height, 0.0001)
      )
    )
  }

  private static func imageRectToPlatterRect(
    _ rect: CGRect,
    crop: EditingCrop
  ) -> CGRect {
    let contentSize = crop.scrollViewContentSize()
    return rect.applying(
      CGAffineTransform(
        scaleX: contentSize.width / max(crop.imageSize.width, 0.0001),
        y: contentSize.height / max(crop.imageSize.height, 0.0001)
      )
    )
  }

  #if DEBUG
  private static func debugDescription(_ size: CGSize) -> String {
    "(w:\(debugNumber(size.width)), h:\(debugNumber(size.height)))"
  }

  private static func debugDescription(_ point: CGPoint) -> String {
    "(x:\(debugNumber(point.x)), y:\(debugNumber(point.y)))"
  }

  private static func debugDescription(_ inset: UIEdgeInsets) -> String {
    "(top:\(debugNumber(inset.top)), left:\(debugNumber(inset.left)), bottom:\(debugNumber(inset.bottom)), right:\(debugNumber(inset.right)))"
  }

  private static func debugAspectRatio(_ size: CGSize) -> String {
    guard size.height != 0 else {
      return "invalid"
    }

    return debugNumber(size.width / size.height)
  }

  private static func debugNumber(_ value: CGFloat) -> String {
    String(format: "%.4f", Double(value))
  }
  #endif

  private func setProposedCrop(
    _ crop: EditingCrop,
    previousCrop: EditingCrop? = nil,
    forcesLayout: Bool = false,
    animatesLayout: Bool = true
  ) {
    let previousCrop = previousCrop ?? state.proposedCrop
    let hasChanges = updateProposedCrop(crop)

    guard hasChanges || forcesLayout else {
      return
    }

    updateCropLayout(previousCrop: previousCrop, animatesLayout: animatesLayout)
  }

  private func emitStateSnapshot() {
    stateHandler(state.snapshot)
  }

  @discardableResult
  private func updateProposedCrop(_ crop: EditingCrop) -> Bool {
    guard state.proposedCrop != crop else {
      return false
    }

    state.proposedCrop = crop

    if isAutoApplyEditingStackEnabled {
      applyCropToEditingStackIfRenderingChanged(crop)
    }

    emitStateSnapshot()

    return true
  }

  #if DEBUG
  private func debugLogRecordedCropExtent(
    source: ScrollViewAdjustmentKind?,
    normalizedRect: CGRect,
    resolvedRect: CGRect
  ) {
    guard state.preferredAspectRatio != nil || source != nil else {
      return
    }

    EditorLog.debug(.cropView, """
      [CropRecord]
      source: \(String(describing: source))
      preferredAspectRatio: \(String(describing: state.preferredAspectRatio))
      normalizedAspect: \(Self.debugAspectRatio(normalizedRect.size))
      resolvedAspect: \(Self.debugAspectRatio(resolvedRect.size))
      """)
  }

  private func debugLogScrollViewAdjustment(_ event: String) {
    guard state.preferredAspectRatio != nil || scrollViewAdjustmentSession != nil else {
      return
    }

    let scrollViewState = """
      zoomScale:\(Self.debugNumber(cropSurface.scrollView.zoomScale)) \
      minZoom:\(Self.debugNumber(cropSurface.scrollView.minimumZoomScale)) \
      maxZoom:\(Self.debugNumber(cropSurface.scrollView.maximumZoomScale)) \
      contentSize:\(Self.debugDescription(cropSurface.scrollView.contentSize)) \
      contentOffset:\(Self.debugDescription(cropSurface.scrollView.contentOffset)) \
      contentInset:\(Self.debugDescription(cropSurface.scrollView.contentInset)) \
      isZooming:\(cropSurface.scrollView.isZooming) \
      isZoomBouncing:\(cropSurface.scrollView.isZoomBouncing) \
      isDragging:\(cropSurface.scrollView.isDragging) \
      isTracking:\(cropSurface.scrollView.isTracking) \
      isDecelerating:\(cropSurface.scrollView.isDecelerating) \
      isResting:\(cropSurface.scrollView.isContentOffsetResting)
      """

    EditorLog.debug(.cropView, """
      [CropScroll] \(event)
      scrollKind: \(String(describing: scrollViewAdjustmentKind))
      scroll: \(scrollViewState)
      """)
  }
  #else
  private func debugLogRecordedCropExtent(
    source: ScrollViewAdjustmentKind?,
    normalizedRect: CGRect,
    resolvedRect: CGRect
  ) {}

  private func debugLogScrollViewAdjustment(_ event: String) {}
  #endif

  private func applyCropToEditingStackIfRenderingChanged(_ crop: EditingCrop) {
    guard let currentCrop = editingStack.loadedState?.currentEdit.crop else {
      editingStack.crop(crop)
      return
    }

    guard currentCrop.isRenderingEquivalent(to: crop) == false else {
      return
    }

    editingStack.crop(crop)
  }

  private func updateCropLayout(
    previousCrop: EditingCrop? = nil,
    animatesLayout: Bool = true
  ) {
    guard let crop = state.proposedCrop else {
      return
    }

    guard state.frame != .zero else {
      return
    }

    setupScrollViewOnce: do {
      if hasSetupScrollViewCompleted == false {
        hasSetupScrollViewCompleted = true

        cropSurface.imagePlatterView.bounds = .init(
          origin: .zero,
          size: crop.scrollViewContentSize()
        )

        // Do we need this? it seems ImageView's bounds changes contentSize automatically. not sure.
        UIView.performWithoutAnimation {
          let currentZoomScale = cropSurface.scrollView.zoomScale
          let contentSize = crop.scrollViewContentSize()
          if cropSurface.scrollView.contentSize != contentSize {
            cropSurface.scrollView.contentInset = .zero
            cropSurface.scrollView.zoomScale = 1
            cropSurface.scrollView.contentSize = contentSize
            cropSurface.scrollView.zoomScale = currentZoomScale
          }
        }
      }
    }

    let animationSourceCrop = previousCrop ?? lastLaidOutCrop
    updateScrollContainerView(
      by: crop,
      preferredAspectRatio: state.preferredAspectRatio,
      animated: animatesLayout
        && areAnimationsEnabled
        && animationSourceCrop != nil /* whether first time load */,
      animatesRotation: animationSourceCrop?.rotation != crop.rotation
    )

    updateCropDisplayViewport()
    lastLaidOutCrop = crop
  }

  override func layoutSubviews() {
    super.layoutSubviews()

    // TODO: Get an optimized size
    guideOutsideContainerView.frame.size = .init(
      width: UIScreen.main.bounds.width * 1.5,
      height: UIScreen.main.bounds.height * 1.5
    )
    guideOutsideContainerView.center = center

    if let cropOutsideOverlay {
      cropOutsideOverlay.frame = guideOutsideContainerView.bounds
    }

    /// to update masking with cropOutsideOverlay
    guideView.setNeedsLayout()

    let previousFrame = state.frame
    if previousFrame != frame {
      state.frame = frame
      updateCropLayout()
    }

    #if DEBUG
    surfaceHost.platterView.layer.addSublayer(_debug_shapeLayer)
    #endif

    updateCropDisplayViewport()
    updateToolCropDisplayViewport()
  }

  private func updateScrollContainerView(
    by crop: EditingCrop,
    preferredAspectRatio: PixelAspectRatio?,
    animated: Bool,
    animatesRotation: Bool
  ) {
    func perform() {

      frame: do {

        let contentRect: CGRect = {

          let bounds = self.bounds.inset(by: contentInset)

          let size = PixelAspectRatio(crop.cropExtent.size)
            .sizeThatFits(in: bounds.size)

          return .init(
            origin: .init(
              x: contentInset.left + ((bounds.width - size.width) / 2) /* centering offset */,
              y: contentInset.top + ((bounds.height - size.height) / 2) /* centering offset */
            ),
            size: size
          )
        }()

        let length: CGFloat = 1600
        let scrollViewFrame = CGRect(
          origin: .zero,
          size: .init(width: length, height: length)
        )

        if clipsToGuide {
          surfaceHost.platterView.bounds.size = contentRect.size
          surfaceHost.platterView.clipsToBounds = true
        } else {
          surfaceHost.platterView.bounds.size = scrollViewFrame.size
          surfaceHost.platterView.clipsToBounds = false
        }

        surfaceHost.platterView.center = .init(x: self.bounds.midX, y: self.bounds.midY)

        cropSurface.scrollView.bounds.size = scrollViewFrame.size
        cropSurface.scrollView.center = CGPoint(
          x: surfaceHost.platterView.bounds.midX,
          y: surfaceHost.platterView.bounds.midY
        )

        surfaceHost.backdropView.bounds.size = scrollViewFrame.size
        surfaceHost.backdropView.center = CGPoint(
          x: surfaceHost.platterView.bounds.midX,
          y: surfaceHost.platterView.bounds.midY
        )

        guideMaximumView.frame = contentRect
        guideBackdropView.frame = contentRect

        guideShadowingView.frame = {

          let bounds = self.bounds.inset(by: contentInset)

          let size = PixelAspectRatio(crop.cropExtent.size)
            .sizeThatFits(in: bounds.size)

          return .init(
            origin: .init(
              x: ((contentInset.left + contentInset.right) / 2)
                + ((bounds.width - size.width) / 2) /* centering offset */,
              y: ((contentInset.top + contentInset.bottom) / 2)
                + ((bounds.height - size.height) / 2) /* centering offset */
            ),
            size: size
          )
        }()

        guideView.frame = contentRect

        cropSurface.scrollView.transform = CGAffineTransform(
          rotationAngle: crop.aggregatedRotation.radians
        )

        updateScrollViewInset(crop: crop)

        // zoom
        do {

          cropSurface.imagePlatterView.frame.origin = .zero

          let (min, max) = crop.calculateZoomScale(
            visibleSize: guideView.bounds
              .applying(CGAffineTransform(rotationAngle: crop.aggregatedRotation.radians))
              .size
          )

          cropSurface.scrollView.minimumZoomScale = min
          cropSurface.scrollView.maximumZoomScale = max

          cropSurface.scrollView.customZoom(
            to: crop.zoomExtent(),
            guideSize: guideView.bounds.size,
            adjustmentRotation: crop.aggregatedRotation.radians,
            animated: false
          )

          if isZoomEnabled == false {
            let scale = cropSurface.scrollView.zoomScale
            cropSurface.scrollView.minimumZoomScale = scale
            cropSurface.scrollView.maximumZoomScale = scale
          }

          updateToolScrollGeometry(crop: crop)

        }

        updateCropDisplayViewport()
        updateToolCropDisplayViewport()
      }

    }

    if animated {
      layoutIfNeeded()

      if animatesRotation {
        UIViewPropertyAnimator(duration: 0.6, dampingRatio: 1) {
          perform()
        }&>.do {
          $0.isUserInteractionEnabled = false
          $0.startAnimation()
        }

        UIViewPropertyAnimator(duration: 0.12, dampingRatio: 1) {
          self.guideView.alpha = 0
        }&>.do {
          $0.isUserInteractionEnabled = false
          $0.addCompletion { _ in
            UIViewPropertyAnimator(duration: 0.5, dampingRatio: 1) {
              self.setCropGuideVisibility(isVisible: self.surfaceMode == .crop)
            }
            .startAnimation(afterDelay: 0.8)
          }
          $0.startAnimation()
        }

      } else {
        UIViewPropertyAnimator(duration: 0.6, dampingRatio: 1) { [self] in
          perform()
          layoutIfNeeded()
        }&>.do {
          $0.startAnimation()
        }
      }

    } else {
      UIView.performWithoutAnimation {
        layoutIfNeeded()
        perform()
      }
    }
  }

  @inline(__always)
  private func willChangeGuideView() {
    // flush scheduled debouncing
    debounce.on { /* for debounce */  }
  }

  private func makeScrollViewInset(aggregatedRotaion: CGFloat) -> UIEdgeInsets {

    let o: CGPoint = {

      let base =
        guideBackdropView
        .convert(
          guideBackdropView.bounds,
          to: surfaceHost.backdropView
        )

      let actualRect =
        guideView
        .convert(
          guideView.bounds,
          to: surfaceHost.backdropView
        )

      return CGPoint(
        x: base.midX - actualRect.midX,
        y: base.midY - actualRect.midY
      )

    }()

    let anchorOffset = CGPoint(
      x: (guideView.bounds.width) / 2 + o.x,
      y: (guideView.bounds.height) / 2 + o.y
    )

    let actualRect =
      guideView
      .convert(
        guideView.bounds.applying(
          CGAffineTransform(translationX: -anchorOffset.x, y: -anchorOffset.y)
            .concatenating(.init(rotationAngle: -aggregatedRotaion))
            .concatenating(.init(translationX: anchorOffset.x, y: anchorOffset.y))
        ),
        to: surfaceHost.backdropView
      )

    let bounds = surfaceHost.backdropView.bounds

    let insetsForActual = UIEdgeInsets.init(
      top: actualRect.minY,
      left: actualRect.minX,
      bottom: bounds.maxY - actualRect.maxY,
      right: bounds.maxX - actualRect.maxX
    )

    return insetsForActual
  }

  private func updateScrollViewInset(crop: EditingCrop) {
    cropSurface.scrollView.contentInset = makeScrollViewInset(
      aggregatedRotaion: crop.aggregatedRotation.radians
    )
  }

  private func updateToolScrollGeometry(
    crop: EditingCrop,
    syncsViewportFromCropSurface: Bool = false
  ) {
    guard let geometry = EditingCanvasCropOutputGeometry(crop: crop) else {
      return
    }

    let contentSize = geometry.outputSize
    let isContentSizeChanged = toolSurface.contentView.bounds.size != contentSize
    let shouldResetToolSurface = syncsViewportFromCropSurface
      || isContentSizeChanged
      || toolSurface.crop?.isRenderingEquivalent(to: crop) != true

    if isContentSizeChanged {
      toolSurface.contentView.bounds = CGRect(origin: .zero, size: contentSize)
      toolSurface.contentView.frame = CGRect(origin: .zero, size: contentSize)
      toolSurface.scrollView.contentSize = contentSize
    }

    let toolFrame = self
      .convert(bounds, to: surfaceHost.platterView)
      .standardized
    guard toolFrame.width > 0, toolFrame.height > 0 else {
      return
    }

    toolSurface.scrollView.transform = .identity
    toolSurface.scrollView.frame = toolFrame

    let minZoomScale = min(
      toolFrame.width / max(contentSize.width, 0.0001),
      toolFrame.height / max(contentSize.height, 0.0001)
    )
    toolSurface.scrollView.minimumZoomScale = minZoomScale
    toolSurface.scrollView.maximumZoomScale = max(minZoomScale * 8, minZoomScale)

    if shouldResetToolSurface {
      // Tool mode displays the crop output as its own image. Entering Tool mode
      // resets navigation to the fitted crop-output viewport rather than copying
      // Crop mode's source-image pan and rotation state.
      toolSurface.scrollView.setZoomScale(minZoomScale, animated: false)
      toolSurface.crop = crop
      toolSurface.outputGeometry = geometry
      toolSurface.centerContentInViewport()
      resetToolScrollViewContentOffset()
    } else if toolSurface.scrollView.zoomScale < toolSurface.scrollView.minimumZoomScale {
      toolSurface.scrollView.setZoomScale(toolSurface.scrollView.minimumZoomScale, animated: false)
      toolSurface.centerContentInViewport()
      resetToolScrollViewContentOffset()
    } else if toolSurface.scrollView.zoomScale > toolSurface.scrollView.maximumZoomScale {
      toolSurface.scrollView.setZoomScale(toolSurface.scrollView.maximumZoomScale, animated: false)
      toolSurface.centerContentInViewport()
      resetToolScrollViewContentOffset()
    } else {
      toolSurface.outputGeometry = geometry
      toolSurface.centerContentInViewport()
    }

    surfaceHost.platterView.layer.mask = nil
  }

  private func resetToolScrollViewContentOffset() {
    let scrollView = toolSurface.scrollView
    let contentSize = toolSurface.zoomedContentSize
    let offset = CGPoint(
      x: (contentSize.width - scrollView.bounds.width) / 2,
      y: (contentSize.height - scrollView.bounds.height) / 2
    )
    scrollView.setContentOffset(
      CGPoint(
        x: max(offset.x, -scrollView.contentInset.left),
        y: max(offset.y, -scrollView.contentInset.top)
      ),
      animated: false
    )
  }

  @inline(__always)
  private func didChangeGuideViewWithDelay() {
    guard let crop = state.proposedCrop else {
      return
    }

    let recordedCrop = record() ?? crop

    updateScrollViewInset(crop: recordedCrop)

    /// Triggers layout update later
    debounce.on { [weak self] in
      guard let self else { return }
      self.updateCropLayout()
    }
  }

  @discardableResult
  private func record() -> EditingCrop? {

    // Crop recording only applies while adjusting the crop. In masking/viewing
    // surface modes the scroll view is a free pan/zoom viewport and must not
    // mutate the crop extent.
    guard surfaceMode == .crop else {
      return state.proposedCrop
    }

    guard var crop = state.proposedCrop else {
      return nil
    }

    // remove rotation while converting rect
    let current = cropSurface.scrollView.transform
    let currentGuideViewCenter = guideView.center

    do {
      // rotating support
      let croppingRect = guideView.convert(guideView.bounds, to: guideBackdropView)

      // offsets guide view rect in maximum size
      // for case of adjusted guide view by interaction
      let offsetX = croppingRect.midX - guideBackdropView.bounds.midX
      let offsetY = croppingRect.midY - guideBackdropView.bounds.midY

      // move focusing area to center
      cropSurface.scrollView.transform = CGAffineTransform(rotationAngle: crop.aggregatedRotation.radians)
        .concatenating(.init(translationX: -offsetX, y: -offsetY))
        .concatenating(.init(rotationAngle: -crop.aggregatedRotation.radians))

      // TODO: Find calculation way withoug using convert rect
      // To work correctly, ignoring transform temporarily.

      // move the guide view to center for convert-rect.
      guideView.center = guideBackdropView.center
    }

    // calculate
    let guideRectInImageView = guideView.convert(guideView.bounds, to: cropSurface.imagePlatterView)

    do {
      // restore guide view center same as displaying
      guideView.center = currentGuideViewCenter

      // restore rotation
      cropSurface.scrollView.transform = current
    }

    // make crop extent for image
    // converts rectangle for display into image's geometry.
    let convertedCropExtent = crop.makeCropExtent(
      rect: guideRectInImageView
    )
    let normalizedCropExtent = normalizedCropExtentForScrollViewRecording(
      convertedCropExtent,
      currentCrop: crop
    )
    let resolvedRect = cropExtentRespectingPreferredAspectRatio(
      normalizedCropExtent,
      currentCrop: crop
    )
    debugLogRecordedCropExtent(
      source: scrollViewAdjustmentKind,
      normalizedRect: normalizedCropExtent,
      resolvedRect: resolvedRect
    )

    crop.updateCropExtent(
      resolvedRect
    )
    updateProposedCrop(crop)
    return crop
  }

  private func cropExtentRespectingPreferredAspectRatio(
    _ cropExtent: CGRect,
    currentCrop: EditingCrop
  ) -> CGRect {
    guard let preferredAspectRatio = state.preferredAspectRatio else {
      return cropExtent
    }

    let imageBounds = CGRect(origin: .zero, size: currentCrop.imageSize)
    let boundedCropExtent = imageBounds.intersection(cropExtent)

    guard boundedCropExtent.isNull == false, boundedCropExtent.isEmpty == false else {
      return cropExtent
    }

    return preferredAspectRatio.rectThatFits(in: boundedCropExtent)
  }

  private func normalizedCropExtentForScrollViewRecording(
    _ cropExtent: CGRect,
    currentCrop: EditingCrop
  ) -> CGRect {
    guard
      let adjustmentSession = scrollViewAdjustmentSession,
      adjustmentSession.kind == .drag
    else {
      return cropExtent
    }

    var cropExtent = cropExtent
    let epsilon: CGFloat = 1e-8

    if adjustmentSession.baselineCrop.cropExtent.width
      >= adjustmentSession.baselineCrop.imageSize.width - epsilon
      && currentCrop.cropExtent.width >= currentCrop.imageSize.width - epsilon
    {
      cropExtent.origin.x = 0
      cropExtent.size.width = currentCrop.imageSize.width
    }

    if adjustmentSession.baselineCrop.cropExtent.height
      >= adjustmentSession.baselineCrop.imageSize.height - epsilon
      && currentCrop.cropExtent.height >= currentCrop.imageSize.height - epsilon
    {
      cropExtent.origin.y = 0
      cropExtent.size.height = currentCrop.imageSize.height
    }

    return cropExtent
  }

  private func beginScrollViewAdjustment(_ kind: ScrollViewAdjustmentKind) {
    if kind == .drag, isZoomInteractionActive {
      debugLogScrollViewAdjustment("drag-begin ignored active-zoom")
      return
    }

    guard let baselineCrop = state.proposedCrop else {
      return
    }

    scrollViewAdjustmentSession = .init(kind: kind, baselineCrop: baselineCrop)
    guideView.willBeginScrollViewAdjustment()
  }

  private func endScrollViewAdjustment(_ kind: ScrollViewAdjustmentKind) {
    guard scrollViewAdjustmentSession?.kind == kind else {
      debugLogScrollViewAdjustment("\(kind)-end ignored")
      return
    }

    didChangeScrollView()
    guideView.didEndScrollViewAdjustment()
  }

  private var isZoomInteractionActive: Bool {
    if scrollViewAdjustmentKind == .zoom {
      return true
    }
    return cropSurface.isZoomInteractionActive
  }

  private func didSettleScrollViewAdjustment() {
    debugLogScrollViewAdjustment("settle-begin")

    let recordedCrop = record()

    if
      let baselineCrop = scrollViewAdjustmentSession?.baselineCrop,
      let recordedCrop,
      baselineCrop.isRenderingEquivalent(to: recordedCrop)
    {
      setProposedCrop(baselineCrop)
    }

    debugLogScrollViewAdjustment("settle-end")

    scrollViewAdjustmentSession = nil
  }

  @inline(__always)
  private func didChangeScrollView() {
    debugLogScrollViewAdjustment("settle-scheduled")

    scrollViewSettleDebounce.on { [weak self] in
      guard let self else { return }

      self.debugLogScrollViewAdjustment("settle-check")

      guard self.cropSurface.scrollView.isContentOffsetResting else {
        self.didChangeScrollView()
        return
      }

      self.didSettleScrollViewAdjustment()
    }
  }

  private var viewportRenderingPreferredFramesPerSecond: Int {
    window?.screen.maximumFramesPerSecond ?? UIScreen.main.maximumFramesPerSecond
  }

  private func updateCropViewportDuringScrollInteraction() {
    guard cropSurface.isInteractiveZoomGestureActive == false else {
      stopViewportRendering(for: .crop, appliesViewport: false)
      updateCropDisplayViewport()
      return
    }

    keepViewportRenderingAlive(for: .crop)

    if cropSurface.viewportRendering.isRunning == false {
      updateCropDisplayViewport()
    }
  }

  private func updateToolViewportDuringScrollInteraction() {
    keepViewportRenderingAlive(for: .tool)

    if toolSurface.viewportRendering.isRunning == false {
      updateToolCropDisplayViewport()
    }
  }

  private func beginViewportRendering(for surface: ViewportRenderingSurface) {
    guard canRenderViewport(for: surface) else {
      return
    }

    viewportRenderingState(for: surface).begin(
      preferredFramesPerSecond: viewportRenderingPreferredFramesPerSecond
    )
  }

  private func keepViewportRenderingAlive(for surface: ViewportRenderingSurface) {
    beginViewportRendering(for: surface)

    guard viewportRenderingState(for: surface).isRunning else {
      return
    }

    applyViewport(for: surface)
    scheduleStopViewportRendering(for: surface)
  }

  private func scheduleStopViewportRendering(for surface: ViewportRenderingSurface) {
    let rendering = viewportRenderingState(for: surface)
    guard rendering.isRunning else {
      return
    }

    rendering.stopWorkItem?.cancel()

    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      if self.isViewportZoomInteractionActive(for: surface)
        || self.isViewportPresentationSettled(for: surface) == false
      {
        self.scheduleStopViewportRendering(for: surface)
      } else {
        self.stopViewportRendering(for: surface)
      }
    }

    rendering.stopWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
  }

  private func stopViewportRendering(
    for surface: ViewportRenderingSurface,
    appliesViewport: Bool = true
  ) {
    viewportRenderingState(for: surface).invalidate()

    if surface == .tool {
      toolSurface.centerContentInViewport()
    }

    if appliesViewport {
      applyViewport(for: surface)
    }
  }

  private func viewportRenderingDisplayLinkDidTick(
    _ displayLink: CADisplayLink,
    surface: ViewportRenderingSurface
  ) {
    guard canRenderViewport(for: surface) else {
      stopViewportRendering(for: surface)
      return
    }

    guard surface == .tool || isViewportInteractiveZoomGestureActive(for: surface) == false else {
      stopViewportRendering(for: surface, appliesViewport: false)
      return
    }

    applyViewport(for: surface)

    if isViewportZoomInteractionActive(for: surface) == false,
       isViewportPresentationSettled(for: surface)
    {
      stopViewportRendering(for: surface)
    }
  }

  private func viewportRenderingState(
    for surface: ViewportRenderingSurface
  ) -> ViewportRenderingState {
    switch surface {
    case .crop:
      return cropSurface.viewportRendering
    case .tool:
      return toolSurface.viewportRendering
    }
  }

  private func canRenderViewport(for surface: ViewportRenderingSurface) -> Bool {
    guard window != nil else {
      return false
    }

    switch surface {
    case .crop:
      return cropSurface.hasCanvasView
    case .tool:
      return toolSurface.hasCanvasView
    }
  }

  private func isViewportZoomInteractionActive(for surface: ViewportRenderingSurface) -> Bool {
    switch surface {
    case .crop:
      return isZoomInteractionActive
    case .tool:
      return toolSurface.isZoomInteractionActive
    }
  }

  private func isViewportInteractiveZoomGestureActive(for surface: ViewportRenderingSurface) -> Bool {
    switch surface {
    case .crop:
      return cropSurface.isInteractiveZoomGestureActive
    case .tool:
      return toolSurface.isInteractiveZoomGestureActive
    }
  }

  private func isViewportPresentationSettled(for surface: ViewportRenderingSurface) -> Bool {
    switch surface {
    case .crop:
      return cropSurface.isViewportPresentationSettled
    case .tool:
      return toolSurface.isViewportPresentationSettled
    }
  }

  private func applyViewport(for surface: ViewportRenderingSurface) {
    switch surface {
    case .crop:
      cropSurface.applyViewport(
        makeCropDisplayViewport(),
        viewportProvider: { [weak self] in
          self?.makeCropDisplayViewport()?.editingCanvasViewport
        }
      )
    case .tool:
      toolSurface.applyViewport(
        makeToolCropDisplayViewport(),
        viewportProvider: { [weak self] in
          self?.makeToolCropDisplayViewport()?.editingCanvasViewport
        }
      )
    }
  }

  var remainingScroll: UIEdgeInsets {
    guard let crop = state.proposedCrop else {
      return .zero
    }

    let guideRectInPlatter = guideView.convert(
      guideView.bounds,
      to: cropSurface.imagePlatterView
    )
    return cropSurface.remainingScroll(
      guideRectInPlatter: guideRectInPlatter,
      guideSize: guideView.bounds.size,
      crop: crop
    )
  }
}

extension UIEdgeInsets {
  fileprivate func inversed() -> Self {
    .init(
      top: -top,
      left: -left,
      bottom: -bottom,
      right: -right
    )
  }

  fileprivate func multiplied(_ value: CGFloat) -> Self {
    .init(
      top: top * value,
      left: left * value,
      bottom: bottom * value,
      right: right * value
    )
  }

  fileprivate func minZero() -> Self {
    .init(
      top: max(0, top),
      left: max(0, left),
      bottom: max(0, bottom),
      right: max(0, right)
    )
  }
}

extension CGRect {

  /// Return a rect rotated around center
  fileprivate func rotated(_ radians: Double) -> CGRect {

    let rotated = self.applying(.init(rotationAngle: radians))

    return .init(
      x: self.minX - (rotated.width - self.width) / 2,
      y: self.minY - (rotated.height - self.height) / 2,
      width: rotated.width,
      height: rotated.height
    )
  }

  fileprivate func isNearlyEqual(to other: CGRect, tolerance: CGFloat) -> Bool {
    abs(minX - other.minX) <= tolerance
      && abs(minY - other.minY) <= tolerance
      && abs(width - other.width) <= tolerance
      && abs(height - other.height) <= tolerance
  }

}

private extension CropDisplayViewport {
  var editingCanvasViewport: _EditingCanvasMTKView.Viewport {
    .init(
      visibleContentRect: visibleContentRect,
      visibleCanvasFrame: visibleCanvasFrame,
      zoomScale: zoomScale
    )
  }
}

extension UIScrollView {

  fileprivate var maxContentOffset: CGPoint {
    CGPoint(
      x: contentSize.width - bounds.width + contentInset.right,
      y: contentSize.height - bounds.height + contentInset.bottom
    )
  }

  fileprivate var minContentOffset: CGPoint {
    CGPoint(
      x: -contentInset.left,
      y: -contentInset.top
    )
  }

  fileprivate var isContentOffsetResting: Bool {
    guard isDragging == false, isTracking == false, isDecelerating == false else {
      return false
    }

    let tolerance: CGFloat = 0.5
    let minContentOffset = self.minContentOffset
    let maxContentOffset = self.maxContentOffset

    func isResting(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> Bool {
      value >= min(lower, upper) - tolerance && value <= max(lower, upper) + tolerance
    }

    return isResting(contentOffset.x, lower: minContentOffset.x, upper: maxContentOffset.x)
      && isResting(contentOffset.y, lower: minContentOffset.y, upper: maxContentOffset.y)
  }

  fileprivate func customZoom(
    to rect: CGRect,
    guideSize: CGSize,
    adjustmentRotation: CGFloat,
    animated: Bool
  ) {

    func run() {

      let targetContentSize = rect.size
      let boundSize = guideSize

      let minXScale = boundSize.width / targetContentSize.width
      let minYScale = boundSize.height / targetContentSize.height
      let targetScale = min(minXScale, minYScale)
      setZoomScale(targetScale, animated: false)

      var targetContentOffset =
        rect
        .rotated(adjustmentRotation)
        .applying(.init(scaleX: targetScale, y: targetScale))
        .origin

      targetContentOffset.x -= contentInset.left
      targetContentOffset.y -= contentInset.top

      let maxContentOffset = self.maxContentOffset

      let minContentOffset = self.minContentOffset

      targetContentOffset.x = min(
        max(targetContentOffset.x, minContentOffset.x),
        maxContentOffset.x
      )
      targetContentOffset.y = min(
        max(targetContentOffset.y, minContentOffset.y),
        maxContentOffset.y
      )

      setContentOffset(targetContentOffset, animated: false)

      EditorLog.debug(.cropView, """
        [Zoom]
        input: \(rect),
        bound: \(boundSize),
        targetScale: \(targetScale),
        targetContentOffset: \(targetContentOffset),
        minContentOffset: \(minContentOffset)
        maxContentOffset: \(maxContentOffset)
        """)
    }

    if animated {
      let animator = UIViewPropertyAnimator(duration: 0.6, dampingRatio: 1)
      animator.addAnimations {
        run()
      }
      animator.startAnimation()
    } else {
      run()
    }

  }

}

// MARK: - Editing canvas (brush surface)

public enum CropViewSurfaceMode: Equatable {
  case crop
  case masking(EditingStack.Edit.LocalAdjustmentEffect)
  case viewing

  var localEffect: EditingStack.Edit.LocalAdjustmentEffect? {
    switch self {
    case .crop, .viewing:
      return nil
    case let .masking(effect):
      return effect
    }
  }
}

extension CropView: UIGestureRecognizerDelegate {

  func setSurfaceMode(_ mode: CropViewSurfaceMode) {
    guard surfaceMode != mode else {
      return
    }

    let wasCropMode = surfaceMode == .crop
    let previousEffect = surfaceMode.localEffect
    if wasCropMode && mode != .crop {
      // Leaving Crop mode commits the currently visible crop viewport before
      // Tool mode derives its crop-output display geometry.
      record()
    }

    surfaceMode = mode

    if previousEffect?.editingCanvasEffectIdentity != mode.localEffect?.editingCanvasEffectIdentity {
      editingCanvasLocalAdjustmentLayerID = nil
    }

    applySurfaceMode(syncsToolViewportFromCrop: wasCropMode && mode != .crop)
    syncEditingCanvasLocalEffectIfNeeded()
    updateCurrentEditingStackDisplay()
  }

  func setCanvasBrush(_ brush: EditingCanvasBrush) {
    canvasBrush = brush
    cropSurface.configureCanvas(brush: brush, smoothing: canvasStrokeSmoothing)
    toolSurface.configureCanvas(brush: brush, smoothing: canvasStrokeSmoothing)
  }

  func setCanvasStrokeSmoothing(_ smoothing: EditingCanvasStrokeSmoothingConfiguration) {
    canvasStrokeSmoothing = smoothing
    cropSurface.configureCanvas(brush: canvasBrush, smoothing: smoothing)
    toolSurface.configureCanvas(brush: canvasBrush, smoothing: smoothing)
  }

  /// Applies the active surface's visibility, interaction, and viewport wiring.
  ///
  /// - Parameter syncsToolViewportFromCrop: Pass true when transitioning from
  ///   Crop mode into a Tool mode so viewport-only crop scroll changes are not
  ///   mistaken for reusable Tool scroll state.
  private func applySurfaceMode(syncsToolViewportFromCrop: Bool = false) {
    let isCropMode: Bool
    let isDrawingEnabled: Bool
    switch surfaceMode {
    case .crop:
      isCropMode = true
      isDrawingEnabled = false
    case .viewing:
      isCropMode = false
      isDrawingEnabled = false
    case .masking:
      isCropMode = false
      isDrawingEnabled = true
    }

    if isDrawingEnabled == false {
      toolSurface.cancelStroke()
    }
    toolSurface.drawingGestureRecognizer.isEnabled = isDrawingEnabled

    cropSurface.applyMode(isActive: isCropMode)
    toolSurface.applyMode(isActive: !isCropMode, isDrawingEnabled: isDrawingEnabled)

    if syncsToolViewportFromCrop, let crop = state.proposedCrop {
      updateToolScrollGeometry(crop: crop, syncsViewportFromCropSurface: true)
    }

    setCropGuideVisibility(isVisible: isCropMode)
    surfaceHost.platterView.layer.mask = nil
    updateCropDisplayViewport()
    updateToolCropDisplayViewport()

    if clipsToGuide {
      clipsToGuide = false
    }
  }

  private func setCropGuideVisibility(isVisible: Bool) {
    let alpha: CGFloat = isVisible ? 1 : 0
    let guideViews: [UIView] = [
      guideOutsideContainerView,
      guideMaximumView,
      guideShadowingView,
      guideBackdropView,
      guideView
    ]

    guideViews.forEach { view in
      view.alpha = alpha
    }
  }

  public func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    guard
      gestureRecognizer === toolSurface.drawingGestureRecognizer
        || otherGestureRecognizer === toolSurface.drawingGestureRecognizer
    else {
      return false
    }

    let viewportGestures = [
      toolSurface.scrollView.panGestureRecognizer,
      toolSurface.scrollView.pinchGestureRecognizer
    ]

    return viewportGestures.contains { viewportGesture in
      gestureRecognizer === viewportGesture || otherGestureRecognizer === viewportGesture
    }
  }

  fileprivate func updateCanvasContent(
    loadedState: EditingStack.Loaded,
    crop: EditingCrop
  ) {
    switch surfaceMode {
    case .crop:
      switch displayMode {
      case .cropInteractionImage:
        cropSurface.updateCanvas(
          loadedState: loadedState,
          crop: crop,
          mode: .viewportBase,
          committedStrokes: []
        )
      case .renderedEditPreview:
        cropSurface.updateRenderedEditPreview(loadedState: loadedState, crop: crop)
      }
    case .viewing, .masking:
      cropSurface.hideCanvasView()
    }
  }

  fileprivate func commitCanvasStroke(
    record: EditingCanvasStrokeRecord,
    completion: @escaping () -> Void
  ) {
    let committedRecord: EditingCanvasStrokeRecord
    if
      surfaceMode != .crop,
      let crop = state.proposedCrop,
      let geometry = EditingCanvasCropOutputGeometry(crop: crop)
    {
      committedRecord = geometry.sourceRecord(fromOutputRecord: record)
    } else {
      committedRecord = record
    }

    appendRecordToEditingStack(committedRecord)
    syncCommittedStrokesFromEditingStack()
    completion()
  }

  private func appendRecordToEditingStack(_ record: EditingCanvasStrokeRecord) {
    guard let currentLocalEffect = surfaceMode.localEffect else {
      return
    }

    var localAdjustments = editingStack.loadedState?.currentEdit.localAdjustments ?? []
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
    editingStack.set(localAdjustments: localAdjustments)
  }

  private func syncEditingCanvasLocalEffectIfNeeded() {
    // TODO: Revisit whether the masking surface can make this sync unnecessary
    // by deriving the displayed and committed effect from one source of truth.
    guard let currentLocalEffect = surfaceMode.localEffect else {
      return
    }

    var localAdjustments = editingStack.loadedState?.currentEdit.localAdjustments ?? []
    guard let layerIndex = editingCanvasLayerIndex(in: localAdjustments) else {
      return
    }

    guard localAdjustments[layerIndex].effect != currentLocalEffect else {
      return
    }

    localAdjustments[layerIndex].effect = currentLocalEffect
    editingStack.set(localAdjustments: localAdjustments)
  }

  private func syncCommittedStrokesFromEditingStack() {
    let sourceRecords = currentSourceCommittedStrokes()
    cropSurface.setCommittedStrokes(sourceRecords)

    guard
      let crop = state.proposedCrop,
      let geometry = EditingCanvasCropOutputGeometry(crop: crop)
    else {
      toolSurface.setCommittedStrokes(sourceRecords)
      return
    }

    toolSurface.setCommittedStrokes(
      sourceRecords.map { geometry.outputRecord(fromSourceRecord: $0) }
    )
  }

  private func currentToolCommittedStrokes(
    in geometry: EditingCanvasCropOutputGeometry
  ) -> [EditingCanvasStrokeRecord] {
    currentSourceCommittedStrokes().map {
      geometry.outputRecord(fromSourceRecord: $0)
    }
  }

  private func currentSourceCommittedStrokes() -> [EditingCanvasStrokeRecord] {
    let localAdjustments = editingStack.loadedState?.currentEdit.localAdjustments ?? []
    guard let layerIndex = editingCanvasLayerIndex(in: localAdjustments) else {
      return []
    }

    return localAdjustments[layerIndex].mask.strokes.map {
      EditingCanvasStrokeRecord(localAdjustmentStroke: $0)
    }
  }

  private func editingCanvasLayerIndex(
    in localAdjustments: [EditingStack.Edit.LocalAdjustmentLayer]
  ) -> Int? {
    guard let currentLocalEffect = surfaceMode.localEffect else {
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
}
