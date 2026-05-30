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
/// Crop mode edits the final crop frame. Tool modes, such as blur masking,
/// paint or inspect the pre-final-crop image domain while using the crop frame
/// as the visible viewport and final clipping boundary. In practice, this means
/// tool navigation must not mutate crop geometry, and tool previews should avoid
/// drawing pixels that would be clipped by the final crop.
///
/// Crop adjustment is available in two ways:
/// - Scrolling the image.
/// - Panning the guide.
///
/// - TODO:
///   - Implicit animations occurs in first time load with remote image.
final class CropView: UIView, UIScrollViewDelegate {

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
  private final class CropSurface {
    let scrollView = _ScrollView()
    let imagePlatterView = ImagePlatterView()
    var canvasView: _EditingCanvasMTKView?
    var canvasSize: CGSize?
    var currentCanvasInputKey: CanvasInputKey?

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

    func applyViewport(_ viewport: CropDisplayViewport?) {
      guard let canvasView else {
        return
      }

      guard let viewport else {
        canvasView.isHidden = true
        return
      }

      canvasView.isHidden = false
      canvasView.frame = viewport.viewportFrameInScrollView
      canvasView.contentScaleFactor = viewport.contentScaleFactor
      canvasView.setViewport(
        visibleContentRect: viewport.visibleContentRect,
        visibleCanvasFrame: viewport.visibleCanvasFrame,
        zoomScale: viewport.zoomScale
      )
    }

    func applyMode(isActive: Bool) {
      scrollView.isScrollEnabled = isActive
      scrollView.pinchGestureRecognizer?.isEnabled = isActive
      scrollView.isHidden = !isActive
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
  /// before the final Crop Feature.
  ///
  /// The tool surface has its own scroll view because Tool navigation is a
  /// viewing interaction over the evaluated result; it must not mutate the Crop
  /// Feature's scroll geometry.
  private final class ToolSurface {
    let scrollView = _ScrollView()
    let contentView = UIView()
    let drawingGestureRecognizer = _EditingCanvasDrawingGestureRecognizer(target: nil, action: nil)
    /// Clips the whole Tool surface to the final crop viewport.
    let cropClipLayer: CAShapeLayer = {
      let layer = CAShapeLayer()
      layer.fillColor = UIColor.white.cgColor
      return layer
    }()
    /// Darkens the non-crop area around the visible crop boundary.
    ///
    /// The path is an even-odd fill in the same coordinate space as
    /// `cropBoundaryOverlayLayer`, so the crop rectangle stays clear while the
    /// surrounding area is visually pushed back.
    let cropBoundaryDimmingLayer: CAShapeLayer = {
      let layer = CAShapeLayer()
      layer.fillColor = UIColor.black.withAlphaComponent(0.45).cgColor
      layer.fillRule = .evenOdd
      layer.isHidden = true
      return layer
    }()
    let cropBoundaryOverlayLayer: CAShapeLayer = {
      let layer = CAShapeLayer()
      layer.fillColor = UIColor.clear.cgColor
      layer.strokeColor = UIColor.clear.cgColor
      layer.lineJoin = .round
      layer.lineCap = .round
      layer.shadowColor = UIColor.black.cgColor
      layer.shadowOpacity = 0
      layer.shadowRadius = 2
      layer.shadowOffset = .zero
      layer.isHidden = true
      return layer
    }()
    var canvasView: _EditingCanvasMTKView?
    var canvasSize: CGSize?
    var crop: EditingCrop?
    weak var cropBoundaryOverlayContainerView: UIView?

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
      canvasView?.layer.mask = nil
      canvasView?.removeFromSuperview()
      canvasView = nil
      canvasSize = nil
      crop = nil
      cropBoundaryDimmingLayer.removeFromSuperlayer()
      cropBoundaryOverlayLayer.removeFromSuperlayer()
      cropBoundaryOverlayContainerView = nil
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

    func applyViewport(_ viewport: CropDisplayViewport?) {
      guard let canvasView else {
        return
      }

      guard let viewport else {
        canvasView.isHidden = true
        return
      }

      canvasView.isHidden = false
      canvasView.frame = viewport.viewportFrameInScrollView
      canvasView.contentScaleFactor = viewport.contentScaleFactor
      canvasView.setViewport(
        visibleContentRect: viewport.visibleContentRect,
        visibleCanvasFrame: viewport.visibleCanvasFrame,
        zoomScale: viewport.zoomScale
      )
    }

    func applyMode(
      isActive: Bool,
      isDrawingEnabled: Bool
    ) {
      scrollView.isHidden = !isActive
      scrollView.isScrollEnabled = isActive
      scrollView.pinchGestureRecognizer?.isEnabled = isActive
      scrollView.panGestureRecognizer.minimumNumberOfTouches = isDrawingEnabled ? 2 : 1
    }

    func hideCropBoundary() {
      canvasView?.layer.mask = nil
      cropBoundaryDimmingLayer.removeFromSuperlayer()
      cropBoundaryDimmingLayer.path = nil
      cropBoundaryDimmingLayer.isHidden = true
      cropBoundaryOverlayLayer.removeFromSuperlayer()
      cropBoundaryOverlayLayer.path = nil
      cropBoundaryOverlayLayer.isHidden = true
      cropBoundaryOverlayContainerView = nil
    }

    func updateCropBoundary(
      cropRectInPlatter: CGRect,
      platterBounds: CGRect,
      cropBoundaryOverlayPath: CGPath,
      cropBoundaryOverlayBounds: CGRect,
      cropBoundaryOverlayContainerView: UIView
    ) {
      self.cropBoundaryOverlayContainerView = cropBoundaryOverlayContainerView
      cropClipLayer.frame = platterBounds
      cropClipLayer.path = UIBezierPath(rect: cropRectInPlatter).cgPath

      if cropBoundaryDimmingLayer.superlayer !== cropBoundaryOverlayContainerView.layer {
        cropBoundaryDimmingLayer.removeFromSuperlayer()
        cropBoundaryOverlayContainerView.layer.addSublayer(cropBoundaryDimmingLayer)
      }

      cropBoundaryOverlayLayer.removeFromSuperlayer()
      cropBoundaryOverlayContainerView.layer.addSublayer(cropBoundaryOverlayLayer)

      CATransaction.begin()
      CATransaction.setDisableActions(true)
      cropBoundaryDimmingLayer.frame = cropBoundaryOverlayBounds
      cropBoundaryDimmingLayer.path = Self.makeBoundaryDimmingPath(
        bounds: CGRect(origin: .zero, size: cropBoundaryOverlayBounds.size),
        cropBoundaryPath: cropBoundaryOverlayPath
      )
      cropBoundaryDimmingLayer.isHidden = false
      cropBoundaryOverlayLayer.frame = cropBoundaryOverlayBounds
      cropBoundaryOverlayLayer.path = cropBoundaryOverlayPath
      updateCropBoundaryLineWidth()
      cropBoundaryOverlayLayer.isHidden = false
      CATransaction.commit()
    }

    func updateCropBoundaryLineWidth() {
      cropBoundaryOverlayLayer.lineWidth = 1
    }

    private static func makeBoundaryDimmingPath(
      bounds: CGRect,
      cropBoundaryPath: CGPath
    ) -> CGPath {
      let path = CGMutablePath()
      path.addRect(bounds)
      path.addPath(cropBoundaryPath)
      return path
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

  private var viewportRenderingDisplayLink: CADisplayLink?
  private var viewportRenderingStopWorkItem: DispatchWorkItem?

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

    configureViewIdentifiers()

    surfaceHost.backdropView.accessibilityIdentifier = "scrollBackdropView"

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

    configureToolDrawingGesture()

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

    cropSurface.scrollView.delegate = self
    toolSurface.scrollView.delegate = self

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

  private func configureViewIdentifiers() {
    accessibilityIdentifier = "CropView"
    surfaceHost.platterView.accessibilityIdentifier = "CropView.surfaceHost.platterView"
    cropSurface.scrollView.accessibilityIdentifier = "CropView.cropSurface.scrollView"
    cropSurface.imagePlatterView.accessibilityIdentifier = "CropView.cropSurface.imagePlatterView"
    toolSurface.scrollView.accessibilityIdentifier = "CropView.toolSurface.scrollView"
    toolSurface.contentView.accessibilityIdentifier = "CropView.toolSurface.contentView"
  }

  private func configureToolDrawingGesture() {
    toolSurface.drawingGestureRecognizer.delegate = self
    toolSurface.drawingGestureRecognizer.isEnabled = false
    toolSurface.drawingGestureRecognizer.onBegin = { [weak self] point in
      guard let self else { return }
      self.toolSurface.beginStroke(at: self.imagePoint(fromPlatterPoint: point))
    }
    toolSurface.drawingGestureRecognizer.onMove = { [weak self] points in
      guard let self else { return }
      self.toolSurface.appendStroke(
        points: points.map { self.imagePoint(fromPlatterPoint: $0) }
      )
    }
    toolSurface.drawingGestureRecognizer.onEnd = { [weak self] point in
      guard let self else { return }
      self.toolSurface.endStroke(at: self.imagePoint(fromPlatterPoint: point))
    }
    toolSurface.drawingGestureRecognizer.onCancel = { [weak self] in
      self?.toolSurface.cancelStroke()
    }
  }

  @available(*, unavailable)
  public required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    stopViewportInteractionRendering()
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

  func setAdjustmentAngle(_ angle: EditingCrop.AdjustmentAngle) {
    guard var crop = state.proposedCrop, crop.adjustmentAngle != angle else {
      return
    }

    crop.adjustmentAngle = angle
    setProposedCrop(crop)

    record()
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

    if surfaceMode == .crop {
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
    } else {
      cropSurface.hideCanvasView()
      guard
        toolSurface.ensureCanvasView(
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

      updateToolCanvasContent(loadedState: loadedState, crop: crop)
      updateToolCropDisplayViewport()
    }
  }

  private func updateToolCanvasContent(
    loadedState: EditingStack.Loaded,
    crop: EditingCrop
  ) {
    switch surfaceMode {
    case .crop:
      toolSurface.hideCanvasView()

    case .viewing:
      toolSurface.updateCanvas(
        loadedState: loadedState,
        crop: crop,
        mode: .renderedEditPreview,
        committedStrokes: []
      )

    case let .masking(effect):
      toolSurface.updateCanvas(
        loadedState: loadedState,
        crop: crop,
        mode: .localAdjustment(effect: effect),
        committedStrokes: currentToolCommittedStrokes()
      )
    }
  }

  private func updateCropDisplayViewport() {
    guard surfaceMode == .crop else {
      cropSurface.hideCanvasView()
      stopViewportInteractionRendering()
      return
    }

    cropSurface.applyViewport(makeCropDisplayViewport())
  }

  private func updateToolCropDisplayViewport() {
    guard surfaceMode != .crop else {
      toolSurface.hideCanvasView()
      return
    }

    updateToolCropMask()
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

  private enum CanvasRenderPlan: Equatable {
    case viewportBase
    case singleLocalAdjustment(EditingStack.Edit.LocalAdjustmentLayer)
    case renderedEditPreview

    init(localAdjustments: [EditingStack.Edit.LocalAdjustmentLayer]) {
      let activeLayers = localAdjustments.filter {
        $0.isEnabled && $0.effect.isActive && $0.mask.isEmpty == false
      }

      switch activeLayers.count {
      case 0:
        self = .viewportBase
      case 1:
        self = .singleLocalAdjustment(activeLayers[0])
      default:
        self = .renderedEditPreview
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

    let viewportFrame = convert(bounds, to: cropSurface.scrollView).standardized
    guard viewportFrame.width > 0, viewportFrame.height > 0 else {
      return nil
    }

    let platterBounds = CGRect(origin: .zero, size: cropSurface.imagePlatterView.bounds.size)
    let visiblePlatterRect = cropSurface.scrollView
      .convert(viewportFrame, to: cropSurface.imagePlatterView)
      .intersection(platterBounds)

    guard visiblePlatterRect.isNull == false, visiblePlatterRect.isEmpty == false else {
      return nil
    }

    let imageBounds = CGRect(origin: .zero, size: crop.imageSize)
    let visibleImageRect = platterRectToImageRect(visiblePlatterRect, crop: crop)
      .intersection(imageBounds)

    guard visibleImageRect.isNull == false, visibleImageRect.isEmpty == false else {
      return nil
    }

    let resolvedVisiblePlatterRect = imageRectToPlatterRect(visibleImageRect, crop: crop)
    let resolvedVisibleScrollRect = cropSurface.imagePlatterView.convert(
      resolvedVisiblePlatterRect,
      to: cropSurface.scrollView
    )
    let visibleCanvasFrame = resolvedVisibleScrollRect.offsetBy(
      dx: -viewportFrame.minX,
      dy: -viewportFrame.minY
    )

    return .init(
      viewportFrameInScrollView: viewportFrame,
      visibleContentRect: visibleImageRect,
      visibleCanvasFrame: visibleCanvasFrame,
      zoomScale: cropSurface.scrollView.zoomScale,
      contentScaleFactor: window?.screen.scale ?? UIScreen.main.scale
    )
  }

  private func makeToolCropDisplayViewport() -> CropDisplayViewport? {
    guard let crop = state.proposedCrop else {
      return nil
    }

    let canvasFrame = convert(bounds, to: toolSurface.scrollView).standardized
    guard canvasFrame.width > 0, canvasFrame.height > 0 else {
      return nil
    }

    let cropViewportFrame = guideView
      .convert(guideView.bounds, to: toolSurface.scrollView)
      .standardized
    guard cropViewportFrame.width > 0, cropViewportFrame.height > 0 else {
      return nil
    }

    let platterBounds = CGRect(origin: .zero, size: toolSurface.contentView.bounds.size)
    let visiblePlatterRect = toolSurface.scrollView
      .convert(cropViewportFrame, to: toolSurface.contentView)
      .intersection(platterBounds)

    guard visiblePlatterRect.isNull == false, visiblePlatterRect.isEmpty == false else {
      return nil
    }

    let imageBounds = CGRect(origin: .zero, size: crop.imageSize)
    let visibleImageRect = platterRectToImageRect(visiblePlatterRect, crop: crop)
      .intersection(imageBounds)

    guard visibleImageRect.isNull == false, visibleImageRect.isEmpty == false else {
      return nil
    }

    let resolvedVisiblePlatterRect = imageRectToPlatterRect(visibleImageRect, crop: crop)
    let resolvedVisibleScrollRect = toolSurface.contentView.convert(
      resolvedVisiblePlatterRect,
      to: toolSurface.scrollView
    )
    let visibleCanvasFrame = resolvedVisibleScrollRect.offsetBy(
      dx: -canvasFrame.minX,
      dy: -canvasFrame.minY
    )

    return .init(
      viewportFrameInScrollView: canvasFrame,
      visibleContentRect: visibleImageRect,
      visibleCanvasFrame: visibleCanvasFrame,
      zoomScale: toolSurface.scrollView.zoomScale,
      contentScaleFactor: window?.screen.scale ?? UIScreen.main.scale
    )
  }

  private func platterRectToImageRect(
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

  private func imageRectToPlatterRect(
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

  private func setProposedCrop(
    _ crop: EditingCrop,
    previousCrop: EditingCrop? = nil,
    forcesLayout: Bool = false
  ) {
    let previousCrop = previousCrop ?? state.proposedCrop
    let hasChanges = updateProposedCrop(crop)

    guard hasChanges || forcesLayout else {
      return
    }

    updateCropLayout(previousCrop: previousCrop)
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
      normalizedAspect: \(debugAspectRatio(normalizedRect.size))
      resolvedAspect: \(debugAspectRatio(resolvedRect.size))
      """)
  }

  private func debugLogScrollViewAdjustment(_ event: String) {
    guard state.preferredAspectRatio != nil || scrollViewAdjustmentSession != nil else {
      return
    }

    EditorLog.debug(.cropView, """
      [CropScroll] \(event)
      scrollKind: \(String(describing: scrollViewAdjustmentKind))
      scroll: \(debugScrollViewState())
      """)
  }

  private func debugScrollViewState() -> String {
    """
    zoomScale:\(debugNumber(cropSurface.scrollView.zoomScale)) \
    minZoom:\(debugNumber(cropSurface.scrollView.minimumZoomScale)) \
    maxZoom:\(debugNumber(cropSurface.scrollView.maximumZoomScale)) \
    contentSize:\(debugDescription(cropSurface.scrollView.contentSize)) \
    contentOffset:\(debugDescription(cropSurface.scrollView.contentOffset)) \
    contentInset:\(debugDescription(cropSurface.scrollView.contentInset)) \
    isZooming:\(cropSurface.scrollView.isZooming) \
    isZoomBouncing:\(cropSurface.scrollView.isZoomBouncing) \
    isDragging:\(cropSurface.scrollView.isDragging) \
    isTracking:\(cropSurface.scrollView.isTracking) \
    isDecelerating:\(cropSurface.scrollView.isDecelerating) \
    isResting:\(cropSurface.scrollView.isContentOffsetResting)
    """
  }

  private func debugDescription(_ size: CGSize) -> String {
    "(w:\(debugNumber(size.width)), h:\(debugNumber(size.height)))"
  }

  private func debugDescription(_ point: CGPoint) -> String {
    "(x:\(debugNumber(point.x)), y:\(debugNumber(point.y)))"
  }

  private func debugDescription(_ inset: UIEdgeInsets) -> String {
    "(top:\(debugNumber(inset.top)), left:\(debugNumber(inset.left)), bottom:\(debugNumber(inset.bottom)), right:\(debugNumber(inset.right)))"
  }

  private func debugAspectRatio(_ size: CGSize) -> String {
    guard size.height != 0 else {
      return "invalid"
    }

    return debugNumber(size.width / size.height)
  }

  private func debugNumber(_ value: CGFloat) -> String {
    String(format: "%.4f", Double(value))
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

  private func updateCropLayout(previousCrop: EditingCrop? = nil) {
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
      animated: areAnimationsEnabled && animationSourceCrop != nil /* whether first time load */,
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
    updateToolCropMask()
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
    let contentSize = crop.scrollViewContentSize()
    let isContentSizeChanged = toolSurface.contentView.bounds.size != contentSize
    let shouldResetToolSurface = syncsViewportFromCropSurface
      || isContentSizeChanged
      || toolSurface.crop?.isRenderingEquivalent(to: crop) != true

    if isContentSizeChanged {
      toolSurface.contentView.bounds = CGRect(origin: .zero, size: contentSize)
      toolSurface.contentView.frame = CGRect(origin: .zero, size: contentSize)
      toolSurface.scrollView.contentSize = contentSize
    }

    toolSurface.scrollView.bounds.size = cropSurface.scrollView.bounds.size
    toolSurface.scrollView.center = cropSurface.scrollView.center
    toolSurface.scrollView.transform = cropSurface.scrollView.transform
    toolSurface.scrollView.contentInset = cropSurface.scrollView.contentInset
    toolSurface.scrollView.minimumZoomScale = cropSurface.scrollView.minimumZoomScale
    toolSurface.scrollView.maximumZoomScale = max(
      cropSurface.scrollView.zoomScale * 8,
      cropSurface.scrollView.minimumZoomScale * 8,
      cropSurface.scrollView.zoomScale
    )

    if shouldResetToolSurface {
      // Rendering equivalence does not include viewport-only crop scroll changes.
      // When entering Tool mode, copy the live Crop viewport so mask rendering
      // starts from the same zoom/offset the user was just inspecting.
      toolSurface.scrollView.setZoomScale(cropSurface.scrollView.zoomScale, animated: false)
      toolSurface.scrollView.setContentOffset(cropSurface.scrollView.contentOffset, animated: false)
      toolSurface.crop = crop
    } else if toolSurface.scrollView.zoomScale < toolSurface.scrollView.minimumZoomScale {
      toolSurface.scrollView.setZoomScale(toolSurface.scrollView.minimumZoomScale, animated: false)
    } else if toolSurface.scrollView.zoomScale > toolSurface.scrollView.maximumZoomScale {
      toolSurface.scrollView.setZoomScale(toolSurface.scrollView.maximumZoomScale, animated: false)
    }

    updateToolCropMask()
  }

  private func updateToolCropMask() {
    guard surfaceMode != .crop, let crop = state.proposedCrop else {
      surfaceHost.platterView.layer.mask = nil
      toolSurface.hideCropBoundary()
      return
    }

    let cropRect = guideView.convert(guideView.bounds, to: surfaceHost.platterView).standardized
    guard cropRect.width > 0, cropRect.height > 0 else {
      surfaceHost.platterView.layer.mask = nil
      toolSurface.hideCropBoundary()
      return
    }

    toolSurface.updateCropBoundary(
      cropRectInPlatter: cropRect,
      platterBounds: surfaceHost.platterView.bounds,
      cropBoundaryOverlayPath: makeToolCropExtentBoundaryPath(crop: crop, in: self),
      cropBoundaryOverlayBounds: bounds,
      cropBoundaryOverlayContainerView: self
    )
    surfaceHost.platterView.layer.mask = toolSurface.cropClipLayer
  }

  private func makeToolCropBoundaryPathInContent() -> CGPath {
    makeToolCropBoundaryPath(in: toolSurface.contentView)
  }

  private func makeToolCropBoundaryPath(in targetView: UIView) -> CGPath {
    let bounds = guideView.bounds
    let corners = [
      CGPoint(x: bounds.minX, y: bounds.minY),
      CGPoint(x: bounds.maxX, y: bounds.minY),
      CGPoint(x: bounds.maxX, y: bounds.maxY),
      CGPoint(x: bounds.minX, y: bounds.maxY)
    ]
      .map { guideView.convert($0, to: targetView) }

    let path = CGMutablePath()
    guard let first = corners.first else {
      return path
    }

    path.move(to: first)
    corners.dropFirst().forEach { path.addLine(to: $0) }
    path.closeSubpath()
    return path
  }

  private func makeToolCropExtentBoundaryPath(
    crop: EditingCrop,
    in targetView: UIView
  ) -> CGPath {
    let cropRectInContent = imageRectToPlatterRect(crop.cropExtent, crop: crop).standardized
    let cornersInContent = toolCropExtentBoundaryPointsInContent(
      cropRectInContent: cropRectInContent,
      rotationRadians: crop.aggregatedRotation.radians
    )
    let corners = cornersInContent.map { toolSurface.contentView.convert($0, to: targetView) }

    let path = CGMutablePath()
    guard let first = corners.first else {
      return path
    }

    path.move(to: first)
    corners.dropFirst().forEach { path.addLine(to: $0) }
    path.closeSubpath()
    return path
  }

  private func toolCropExtentBoundaryPointsInContent(
    cropRectInContent: CGRect,
    rotationRadians: CGFloat
  ) -> [CGPoint] {
    let corners = [
      CGPoint(x: cropRectInContent.minX, y: cropRectInContent.minY),
      CGPoint(x: cropRectInContent.maxX, y: cropRectInContent.minY),
      CGPoint(x: cropRectInContent.maxX, y: cropRectInContent.maxY),
      CGPoint(x: cropRectInContent.minX, y: cropRectInContent.maxY)
    ]

    guard rotationRadians != 0 else {
      return corners
    }

    let center = CGPoint(x: cropRectInContent.midX, y: cropRectInContent.midY)
    let transform = CGAffineTransform(translationX: center.x, y: center.y)
      .rotated(by: -rotationRadians)
      .translatedBy(x: -center.x, y: -center.y)

    return corners.map { $0.applying(transform) }
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
    if
      scrollViewAdjustmentKind == .zoom
        || cropSurface.scrollView.isZooming
        || cropSurface.scrollView.isZoomBouncing
    {
      return true
    }

    switch cropSurface.scrollView.pinchGestureRecognizer?.state {
    case .began, .changed:
      return true
    case .cancelled, .ended, .failed, .possible, .none:
      return false
    @unknown default:
      return false
    }
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

  private func beginViewportInteractionRendering() {
    guard cropSurface.canvasView != nil,
          viewportRenderingDisplayLink == nil
    else {
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
    if surfaceMode == .crop {
      cropSurface.applyViewport(makeCropDisplayViewport())
    }
  }

  @objc private func viewportRenderingDisplayLinkDidTick(_ displayLink: CADisplayLink) {
    guard window != nil else {
      stopViewportInteractionRendering()
      return
    }

    updateCropDisplayViewport()
  }

  // MARK: UIScrollViewDelegate

  func viewForZooming(in scrollView: UIScrollView) -> UIView? {
    if scrollView === toolSurface.scrollView {
      return toolSurface.contentView
    }

    return cropSurface.imagePlatterView
  }

  func scrollViewDidZoom(_ scrollView: UIScrollView) {
    if scrollView === toolSurface.scrollView {
      toolSurface.updateCropBoundaryLineWidth()
      updateToolCropDisplayViewport()
      return
    }

    debugLogScrollViewAdjustment("did-zoom")
    keepViewportInteractionRenderingAlive()
    updateCropDisplayViewport()

    debounce.on { [weak self] in

      guard let self = self else { return }
      guard self.surfaceMode == .crop else { return }

      self.updateCropLayout()
    }
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    if scrollView === toolSurface.scrollView {
      updateToolCropDisplayViewport()
      return
    }

    debugLogScrollViewAdjustment("did-scroll")
    if isZoomInteractionActive {
      keepViewportInteractionRenderingAlive()
    }
    updateCropDisplayViewport()

    debounce.on { [weak self] in

      guard let self = self else {
        return
      }

      guard self.surfaceMode == .crop else {
        return
      }

      guard self.cropSurface.scrollView.isTracking == false else {
        return
      }

      self.updateCropLayout()
    }
  }

  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    if scrollView === toolSurface.scrollView {
      return
    }

    debugLogScrollViewAdjustment("drag-begin")
    beginScrollViewAdjustment(.drag)
  }

  func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
    if scrollView === toolSurface.scrollView {
      return
    }

    debugLogScrollViewAdjustment("zoom-begin")
    beginViewportInteractionRendering()
    beginScrollViewAdjustment(.zoom)
  }

  func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool)
  {
    if scrollView === toolSurface.scrollView {
      updateToolCropDisplayViewport()
      return
    }

    debugLogScrollViewAdjustment("drag-end decelerate:\(decelerate)")

    if !decelerate {
      endScrollViewAdjustment(.drag)
    }
  }

  func scrollViewDidEndZooming(
    _ scrollView: UIScrollView,
    with view: UIView?,
    atScale scale: CGFloat
  ) {
    if scrollView === toolSurface.scrollView {
      updateToolCropDisplayViewport()
      return
    }

    debugLogScrollViewAdjustment("zoom-end scale:\(scale)")
    endScrollViewAdjustment(.zoom)
    scheduleStopViewportInteractionRendering()
  }

  func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    if scrollView === toolSurface.scrollView {
      updateToolCropDisplayViewport()
      return
    }

    debugLogScrollViewAdjustment("deceleration-end")
    endScrollViewAdjustment(.drag)
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
    updateToolCropMask()
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
    appendRecordToEditingStack(record)
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
    let records = currentToolCommittedStrokes()
    cropSurface.setCommittedStrokes(records)
    toolSurface.setCommittedStrokes(records)
  }

  private func currentToolCommittedStrokes() -> [EditingCanvasStrokeRecord] {
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

  fileprivate func imagePoint(fromPlatterPoint point: CGPoint) -> CGPoint {
    guard let crop = state.proposedCrop else {
      return point
    }

    let contentSize = crop.scrollViewContentSize()
    return CGPoint(
      x: point.x * (crop.imageSize.width / max(contentSize.width, 0.0001)),
      y: point.y * (crop.imageSize.height / max(contentSize.height, 0.0001))
    )
  }
}
