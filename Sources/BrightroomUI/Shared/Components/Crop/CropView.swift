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
import BrightroomParametric

/// A UIKit canvas that previews a point in the document FeatureTree and edits
/// a feature node that may live at a different point.
///
/// Based on the editing vision in `docs/vision-of-editing.md`, this view treats
/// tool edits as Features that happen before the final crop:
///
/// ```text
/// Source -> Tool Features -> Final Crop -> Output
/// ```
///
/// The contract with hosts is `CropViewFeatureFocus`: a viewing point in the
/// FeatureTree plus an optional editing target. Crop editing adjusts the final
/// crop frame while showing the result of earlier Tool Features. Mask editing,
/// such as blur masking, inspects the evaluated result at the viewing point
/// while authoring parameters that still belong to the pre-final-crop image
/// domain. In practice, this means Tool navigation must not mutate crop
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

    var proposedCrop: CropEditingState?

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
    let baselineCrop: CropEditingState
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
  ///
  /// Main-actor isolated: the display link is added to the main run loop, so the
  /// tick callback and lifecycle (`begin`/`invalidate`) all run on the main
  /// actor.
  @MainActor
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

    isolated deinit {
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
  @MainActor
  private final class SurfaceHost {
    let platterView = UIView()
    let backdropView = UIView()
  }

  /// Common core shared by the Crop and Tool surfaces: a UIScrollView that
  /// owns pan/zoom physics over a transparent zooming view, with the Metal
  /// canvas inserted beneath that view so the scroll view never transforms
  /// rendered pixels directly.
  ///
  /// These are reference types because UIKit may re-enter scroll-view delegate
  /// callbacks while a surface is updating its views and layers.
  private class CanvasSurface: NSObject, UIScrollViewDelegate {
    let scrollView = _ScrollView()
    var canvasView: _EditingCanvasMTKView?
    var canvasSize: CGSize?
    let viewportRendering: ViewportRenderingState

    /// The transparent view the scroll view zooms; rendered pixels live on
    /// the Metal canvas inserted beneath it.
    let zoomingView: UIView

    /// Called when the scroll view changes zoom scale.
    var onDidZoom: (() -> Void)?
    /// Called when the scroll view changes content offset.
    var onDidScroll: (() -> Void)?
    /// Called when the user starts dragging the viewport.
    var onWillBeginDragging: (() -> Void)?
    /// Called when the user starts pinching the viewport.
    var onWillBeginZooming: (() -> Void)?
    /// Called when viewport dragging ends.
    var onDidEndDragging: ((_ willDecelerate: Bool) -> Void)?
    /// Called when viewport pinch zooming ends.
    var onDidEndZooming: ((CGFloat) -> Void)?
    /// Called when viewport deceleration ends.
    var onDidEndDecelerating: (() -> Void)?

    init(surface: ViewportRenderingSurface, zoomingView: UIView) {
      self.viewportRendering = ViewportRenderingState(surface: surface)
      self.zoomingView = zoomingView
      super.init()
      scrollView.delegate = self
    }

    var hasCanvasView: Bool {
      canvasView != nil
    }

    /// While true, the canvas is temporarily parented inside `zoomingView`
    /// (with a transform compensating the model zoom scale) so UIKit's own
    /// zoom bounce-back presentation animation carries it. The bounce emits no
    /// per-frame delegate ticks, so this is the only way to move the canvas in
    /// exact phase with the spring; presentation-layer sampling from a display
    /// link is always one frame out of phase.
    private(set) var isRidingZoomBounce = false
    private var zoomBounceRideRestorationFrame: CGRect?

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
      let isZoomingViewFrameSettled = zoomingView.layer.presentation()?.frame
        .isNearlyEqual(to: zoomingView.frame, tolerance: tolerance) ?? true

      return isScrollBoundsSettled && isZoomingViewFrameSettled
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
      scrollView.insertSubview(view, belowSubview: zoomingView)
      canvasView = view
      self.canvasSize = canvasSize
      return view
    }

    func removeCanvasView() {
      endZoomBounceRide()
      viewportRendering.invalidate()
      canvasView?.removeFromSuperview()
      canvasView = nil
      canvasSize = nil
    }

    /// Hands the canvas to the zooming view so the in-flight zoom bounce-back
    /// carries it. Call after applying the settled-model viewport: the frame
    /// and the render must already describe the final geometry so the ride
    /// lands pixel-exact. The reparent and the compensating transform commit
    /// in the same transaction as that render, so the screen never shows the
    /// intermediate model-snapped placement.
    func beginZoomBounceRide() {
      guard
        isRidingZoomBounce == false,
        scrollView.isZoomBouncing,
        let canvasView,
        canvasView.isHidden == false
      else {
        return
      }

      let zoomScale = scrollView.zoomScale
      guard zoomScale > 0 else {
        return
      }

      let frameInScrollView = canvasView.frame
      zoomBounceRideRestorationFrame = frameInScrollView
      let centerInZoomingView = scrollView.convert(
        CGPoint(x: frameInScrollView.midX, y: frameInScrollView.midY),
        to: zoomingView
      )
      // The bounce-start delegate callback runs inside UIKit's own animation
      // context, so plain property writes here would be implicitly animated —
      // the canvas would spring from its old placement instead of being
      // carried by the parent. Place it without animation and strip anything
      // that already attached in this transaction.
      UIView.performWithoutAnimation {
        zoomingView.insertSubview(canvasView, at: 0)
        canvasView.transform = CGAffineTransform(scaleX: 1 / zoomScale, y: 1 / zoomScale)
        canvasView.center = centerInZoomingView
      }
      canvasView.layer.removeAllAnimations()
      isRidingZoomBounce = true
    }

    /// Returns the canvas to its normal scroll-view placement. Visually
    /// continuous when the bounce has settled: the presentation transform has
    /// converged to the model, so the restored scroll-view frame maps to the
    /// same pixels the ride ended on.
    func endZoomBounceRide() {
      guard isRidingZoomBounce else {
        return
      }
      isRidingZoomBounce = false

      let restorationFrame = zoomBounceRideRestorationFrame
      zoomBounceRideRestorationFrame = nil

      guard let canvasView else {
        return
      }
      UIView.performWithoutAnimation {
        canvasView.transform = .identity
        scrollView.insertSubview(canvasView, belowSubview: zoomingView)
        if let restorationFrame {
          canvasView.frame = restorationFrame
        }
      }
      canvasView.layer.removeAllAnimations()
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

    func applyViewport(
      _ viewport: CropDisplayViewport?,
      viewportProvider: _EditingCanvasMTKView.ViewportProvider? = nil
    ) {
      guard let canvasView else {
        return
      }

      // While riding the zoom bounce the canvas lives inside the zooming view
      // with a compensating transform, so scroll-view-space frames don't
      // apply. The model is already settled during the bounce; the viewport
      // applied when the ride ends produces the same geometry.
      guard isRidingZoomBounce == false else {
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

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
      zoomingView
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
  }

  /// Owns the scroll, image platter, and Metal canvas state used while
  /// adjusting the final Crop Feature.
  ///
  /// The crop surface always shows the rendered edit preview: the crop frame
  /// is a viewing window over the fully evaluated result, so global filters —
  /// and, while a single local adjustment layer is active, its mask — stay
  /// visible while choosing the crop. (With two or more active layers,
  /// `CanvasRenderPlan` currently falls back to a filters-only preview.)
  private final class CropSurface: CanvasSurface {

    let imagePlatterView: ImagePlatterView
    var currentCanvasInputKey: CanvasInputKey?

    init() {
      let platterView = ImagePlatterView()
      self.imagePlatterView = platterView
      super.init(surface: .crop, zoomingView: platterView)
    }

    override func removeCanvasView() {
      super.removeCanvasView()
      currentCanvasInputKey = nil
    }

    func updateRenderedEditPreview(
      document: CropViewDocumentSnapshot,
      crop: CropEditingState,
      inputDomainImage: CIImage?,
      inputDomainFeatures: [MainFeature]
    ) {
      guard crop.imageSize == canvasSize, let canvasView else {
        return
      }

      let key = CanvasInputKey(
        document: document,
        crop: crop,
        inputDomainFeatures: inputDomainFeatures
      )
      guard currentCanvasInputKey != key || canvasView.hasRenderImages == false else {
        canvasView.isHidden = false
        return
      }

      let images: EditingCanvasRenderImages?
      let committedStrokes: [EditingCanvasStrokeRecord]

      if let inputDomainImage {
        // Editing a repeated crop upstream of the final crop: its input domain
        // has every upstream feature already baked into `inputDomainImage`, so
        // present it as a flat preview (no residual effects, no live strokes)
        // and let the crop guide frame it.
        images = EditingCanvasRenderImageFactory.makeRenderImages(
          editingSourceImage: inputDomainImage,
          effects: .init(),
          canvasSize: crop.imageSize,
          mode: .renderedEditPreview
        )
        committedStrokes = []
      } else {
        let renderPlan = CanvasRenderPlan(
          localAdjustments: document.localAdjustments
        )
        images = EditingCanvasRenderImageFactory.makeRenderImages(
          document: document,
          canvasSize: crop.imageSize,
          mode: renderPlan.canvasMode
        )
        // This canvas is sized to crop.imageSize, so records stay in the
        // source domain.
        committedStrokes = renderPlan.committedStrokes(in: nil)
      }

      guard let images else {
        return
      }

      canvasView.setRenderImages(images)
      canvasView.setCommittedStrokes(committedStrokes)
      canvasView.isHidden = false
      currentCanvasInputKey = key
    }

    func applyMode(isActive: Bool) {
      if isActive == false {
        viewportRendering.invalidate()
      }
      scrollView.isScrollEnabled = isActive
      scrollView.pinchGestureRecognizer?.isEnabled = isActive
      scrollView.isHidden = !isActive
    }

    func remainingScroll(
      guideRectInPlatter: CGRect,
      guideSize: CGSize,
      crop: CropEditingState
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
  private final class ToolSurface: CanvasSurface {

    /// Inputs that determine the output of
    /// `EditingCanvasRenderImageFactory.makeCropOutputRenderImages`. The source
    /// image is compared by identity; `CropViewDocumentSnapshot` stores it as an
    /// immutable property, so a new editing source always produces a new
    /// instance.
    struct CanvasRenderInputKey: Equatable {
      var sourceImage: ObjectIdentifier
      var effects: EffectPipeline
      var geometry: EditingCanvasCropOutputGeometry
      var mode: EditingCanvasMode
    }

    let contentView: UIView
    let drawingGestureRecognizer = _EditingCanvasDrawingGestureRecognizer(target: nil, action: nil)
    var crop: CropEditingState?
    var outputGeometry: EditingCanvasCropOutputGeometry?
    var currentCanvasRenderInputKey: CanvasRenderInputKey?

    init() {
      let view = UIView()
      view.backgroundColor = .clear
      view.isOpaque = false
      view.accessibilityIdentifier = "toolSurfaceContentView"
      self.contentView = view
      super.init(surface: .tool, zoomingView: view)
    }

    override func removeCanvasView() {
      canvasView?.layer.mask = nil
      super.removeCanvasView()
      crop = nil
      outputGeometry = nil
      currentCanvasRenderInputKey = nil
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

    func updateCanvas(
      document: CropViewDocumentSnapshot,
      geometry: EditingCanvasCropOutputGeometry,
      mode: EditingCanvasMode,
      committedStrokes: [EditingCanvasStrokeRecord]
    ) {
      guard geometry.outputSize == canvasSize, let canvasView else {
        return
      }
      outputGeometry = geometry

      let inputKey = CanvasRenderInputKey(
        sourceImage: ObjectIdentifier(document.editingSourceImage),
        effects: document.effects,
        geometry: geometry,
        mode: mode
      )

      // Hosts call this on every state update (stroke commits, brush changes,
      // unrelated SwiftUI re-renders). Rebuilding identical render-image graphs
      // would discard the canvas's viewport texture caches each time.
      if currentCanvasRenderInputKey != inputKey || canvasView.hasRenderImages == false {
        guard
          let images = EditingCanvasRenderImageFactory.makeCropOutputRenderImages(
            document: document,
            geometry: geometry,
            mode: mode
          )
        else {
          return
        }

        canvasView.setRenderImages(images)
        currentCanvasRenderInputKey = inputKey
      }

      canvasView.setCommittedStrokes(committedStrokes)
      canvasView.isHidden = false
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

  private let document: CropViewDocument

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

  /// The FeatureTree focus driving surface activation: which point in the
  /// tree is previewed and which feature node canvas gestures edit.
  private var featureFocus: CropViewFeatureFocus = .finalCrop
  private var maskingBrush: CropViewMaskingBrush = .init(diameter: .viewportPoints(30))
  /// The image-space brush most recently pushed to the canvas surfaces, used
  /// to skip redundant reconfiguration when neither the brush nor the
  /// geometry it resolves against has changed.
  private var appliedCanvasBrush: EditingCanvasBrush?
  private var canvasStrokeSmoothing: EditingCanvasStrokeSmoothingConfiguration = .init()
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

  private var lastLaidOutCrop: CropEditingState?

  // MARK: - Initializers

  init(
    document: CropViewDocument,
    contentInset: UIEdgeInsets = .init(top: 20, left: 20, bottom: 20, right: 20)
  ) {
    _pixeleditor_ensureMainThread()

    self.document = document
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
          guard self.featureFocus.isCropEditing else { return }
          // This trailing debounce runs updateCropLayout(), which snaps the
          // scroll view back to the not-yet-recorded proposedCrop via
          // customZoom. It must not fire while the user is still touching the
          // content, or that snap reverts an in-progress zoom. Two cases:
          //
          // 1. A held-still pinch (two fingers down, no movement) stops
          //    emitting scrollViewDidZoom events; the pinch recognizer is
          //    still active.
          // 2. One finger lifts mid-pinch (2→1). UIScrollView keeps the zoom
          //    and pans with the remaining finger, but the pinch recognizer
          //    has already ended — so the isInteractiveZoomGestureActive guard
          //    alone would let this fire and revert the zoom.
          //
          // Guard on isTracking (any touch down) to cover both, mirroring the
          // isTracking guard onDidScroll uses for drags. record() runs from the
          // settle path once every touch is up, and the pan's own onDidScroll
          // debounce then re-lays out against the recorded crop.
          guard self.cropSurface.isInteractiveZoomGestureActive == false else { return }
          guard self.cropSurface.scrollView.isTracking == false else { return }

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
          guard self.featureFocus.isCropEditing else { return }
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
        // Only the canvas chase runs here. The scroll model (contentSize /
        // contentInset) is never mutated from zoom ticks: the static fit inset
        // set in updateToolScrollGeometry stays valid through the whole
        // gesture, mirroring the crop surface's static guide inset.
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
      toolSurface.onDidEndDragging = { [weak self] _ in
        self?.updateToolCropDisplayViewport()
      }
      toolSurface.onDidEndZooming = { [weak self] _ in
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

  isolated deinit {
    cropSurface.viewportRendering.invalidate()
    toolSurface.viewportRendering.invalidate()
  }

  // MARK: - Functions

  func setStateHandler(_ handler: @escaping @MainActor (StateSnapshot) -> Void) {
    self.stateHandler = handler
  }

  func loadCurrentDocumentState() {
    let snapshot = document.requireSnapshotForLoadedCropView()
    guard let crop = displayCropEditingState(in: snapshot) else {
      return
    }
    load(crop: crop)
    updateDisplay(document: snapshot)
  }

  func updateCurrentDocumentDisplay() {
    guard let snapshot = document.snapshot else {
      return
    }

    guard let documentCrop = displayCropEditingState(in: snapshot) else {
      return
    }
    if state.proposedCrop == nil || state.proposedCrop?.imageSize != documentCrop.imageSize {
      load(crop: documentCrop)
    }

    updateDisplay(document: snapshot)
  }

  /**
   Renders an image according to the editing.

   - Attention: The UI crop state is committed on the main actor before the
     renderer performs its asynchronous work.
   */
  func renderImage() async throws -> BrightRoomImageRenderer.Rendered? {
    applyDocumentChanges()
    return try await document.renderImage()
  }

  /**
   Applies the current crop state to the document.
   */
  func applyDocumentChanges() {
    guard let crop = record() ?? state.proposedCrop else {
      EditorLog.error(.cropView, "CropViewDocument has not completed loading.")
      return
    }
    applyCropToDocumentIfRenderingChanged(crop)
  }

  func resetCrop() {
    _pixeleditor_ensureMainThread()

    debounce.cancel()
    scrollViewSettleDebounce.cancel()
    scrollViewAdjustmentSession = nil
    isStreamingAdjustmentAngle = false
    state.adjustmentKind = []
    state.preferredAspectRatio = nil
    guideView.setLockedAspectRatio(nil)

    if let crop = state.proposedCrop {
      setProposedCrop(crop.makeInitial(), previousCrop: crop, forcesLayout: true)
    }

    emitStateSnapshot()
  }

  func setRotation(_ rotation: CropEditingState.Rotation) {
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
    _ angle: CropEditingState.AdjustmentAngle,
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

  func commitAdjustmentAngle(_ angle: CropEditingState.AdjustmentAngle) {
    setAdjustmentAngle(angle, recordsCropExtent: false)
    record()
    isStreamingAdjustmentAngle = false
    updateCropDisplayViewport()
  }

  func setCrop(_ crop: CropEditingState) {
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
  private func load(crop: CropEditingState) {
    prepareForCropIfNeeded(crop)
    setProposedCrop(crop, forcesLayout: true)
  }

  private func prepareForCropIfNeeded(_ crop: CropEditingState) {
    if state.proposedCrop?.imageSize != crop.imageSize {
      hasSetupScrollViewCompleted = false
      lastLaidOutCrop = nil
      cropSurface.removeCanvasView()
      toolSurface.removeCanvasView()
    }
  }

  private func updateDisplay(document: CropViewDocumentSnapshot) {
    guard let crop = state.proposedCrop else {
      return
    }

    // The resolved image-space brush tracks the committed crop and view
    // bounds, which can change without the host re-sending the brush.
    refreshCanvasBrushIfNeeded()

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

    if featureFocus.isCropEditing {
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

      updateCanvasContent(document: document, crop: crop)
      updateCropDisplayViewport()

    } else if let seedEffect = resolvedMaskSeedEffect {
      guard
        let geometry = makeToolOutputGeometry(crop: crop),
        ensureToolCanvas(geometry: geometry)
      else {
        return
      }

      // The committed layer's effect is frozen at creation; the focus's seed
      // effect only seeds layers that don't exist yet. Rendering with the
      // committed effect keeps the preview equal to the exported result even
      // when the host recomputes the seed effect from a new crop.
      toolSurface.updateCanvas(
        document: document,
        geometry: geometry,
        mode: .localAdjustment(effect: committedCanvasLocalEffect() ?? seedEffect),
        committedStrokes: currentToolCommittedStrokes(in: geometry)
      )
      updateToolCropDisplayViewport()

    } else {
      guard
        let geometry = makeToolOutputGeometry(crop: crop),
        ensureToolCanvas(geometry: geometry)
      else {
        return
      }

      let renderPlan = CanvasRenderPlan(
        localAdjustments: document.localAdjustments
      )
      toolSurface.updateCanvas(
        document: document,
        geometry: geometry,
        mode: renderPlan.canvasMode,
        committedStrokes: renderPlan.committedStrokes(in: geometry)
      )
      updateToolCropDisplayViewport()
    }
  }

  /// Whether the evaluated image at the current viewing point contains the
  /// final crop. Unknown points fall back to the output behavior.
  private var viewingPointIncludesFinalCrop: Bool {
    switch featureFocus.viewingPoint {
    case .output:
      return true
    case .source:
      return false
    case .after:
      guard
        let tree = document.snapshot?.featureTree,
        let includes = tree.point(
          featureFocus.viewingPoint,
          includes: EditingFeatureTree.finalCropNodeID
        )
      else {
        return true
      }
      return includes
    }
  }

  /// The crop describing the tool surface's display domain for the current
  /// viewing point: the final crop when the viewing point includes it, or the
  /// identity crop (the full pre-crop image) when previewing an earlier point.
  private func toolDisplayCrop(from crop: CropEditingState) -> CropEditingState {
    viewingPointIncludesFinalCrop ? crop : crop.makeInitial()
  }

  /// The source-to-display geometry the tool surface uses for the current
  /// viewing point. Strokes committed through this geometry always land in the
  /// pre-crop feature domain regardless of the viewing point.
  private func makeToolOutputGeometry(crop: CropEditingState) -> EditingCanvasCropOutputGeometry? {
    EditingCanvasCropOutputGeometry(crop: toolDisplayCrop(from: crop))
  }

  private func updateCropDisplayViewport() {
    guard featureFocus.isCropEditing else {
      cropSurface.hideCanvasView()
      stopViewportRendering(for: .crop, appliesViewport: false)
      return
    }

    cropSurface.applyViewport(makeCropDisplayViewport())
  }

  private func updateToolCropDisplayViewport() {
    guard featureFocus.isCropEditing == false else {
      toolSurface.hideCanvasView()
      return
    }

    surfaceHost.platterView.layer.mask = nil
    toolSurface.applyViewport(makeToolCropDisplayViewport())
  }

  private struct CanvasInputKey: Equatable {
    var imageSize: CGSize
    var sourceImage: ObjectIdentifier
    var sourceExtent: CGRect
    var effects: EffectPipeline
    var localAdjustments: [LocalAdjustmentFeature]
    // The upstream features baked into a repeated crop's input-domain preview.
    // Empty for the default source path; captures the prefix by value so an
    // upstream crop or effect change re-renders the crop surface.
    var inputDomainFeatures: [MainFeature]

    init(
      document: CropViewDocumentSnapshot,
      crop: CropEditingState,
      inputDomainFeatures: [MainFeature] = []
    ) {
      let previewSourceImage = document.editingSourceImage.removingExtentOffset()
      self.imageSize = crop.imageSize
      // Extent alone cannot detect a same-size source replacement (the
      // editing source is always capped to the same max pixel size).
      self.sourceImage = ObjectIdentifier(document.editingSourceImage)
      self.sourceExtent = previewSourceImage.extent
      self.effects = document.effects
      self.localAdjustments = document.localAdjustments
      self.inputDomainFeatures = inputDomainFeatures
    }
  }

  // TODO: Consider to remove this
  // Internal (not private) so tests can verify the stroke-domain mapping.
  enum CanvasRenderPlan: Equatable {
    case viewportBase
    case singleLocalAdjustment(LocalAdjustmentFeature)
    case renderedEditPreview

    init(
      localAdjustments: [LocalAdjustmentFeature]
    ) {
      let activeLayers = localAdjustments.filter {
        $0.isEnabled
          && $0.effectPipeline.hasEnabledEffects
          && $0.maskTree.canvasIsEffectivelyEmpty == false
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
        return .localAdjustment(effect: layer.effectPipeline)
      case .renderedEditPreview:
        return .renderedEditPreview
      }
    }

    /// Persisted strokes live in the pre-crop source domain. Pass the
    /// crop-output geometry when the destination canvas displays the crop
    /// output, or nil when the canvas is sized to the source image.
    func committedStrokes(
      in geometry: EditingCanvasCropOutputGeometry?
    ) -> [EditingCanvasStrokeRecord] {
      switch self {
      case .viewportBase, .renderedEditPreview:
        return []
      case let .singleLocalAdjustment(layer):
        let sourceRecords = layer.maskTree.canvasBrushStrokes.map {
          EditingCanvasStrokeRecord(brushMaskStroke: $0)
        }
        guard let geometry else {
          return sourceRecords
        }
        return sourceRecords.map {
          geometry.outputRecord(fromSourceRecord: $0)
        }
      }
    }
  }

  /// The crop state that defines the canvas display domain for the current
  /// document.
  ///
  /// PhotosCrop currently displays the built-in final crop as the viewport even
  /// when a tool edits an upstream feature. Crop editing writes through
  /// `featureFocus.cropTargetID`; display resolution stays here so those two
  /// responsibilities do not collapse back into `Edit.crop`.
  private func displayCropEditingState(
    in document: CropViewDocumentSnapshot
  ) -> CropEditingState? {
    // When the focus edits a specific crop node, load that crop's own geometry
    // against its input domain — the size of the image produced by every
    // upstream feature. For the final crop with no upstream crops this reduces
    // to the source size, matching the single-crop baseline. Non-crop focuses
    // (mask/preview) carry no crop target and frame the final crop as viewport.
    if
      let targetID = featureFocus.cropTargetID,
      let targetCrop = document.cropFeature(id: targetID),
      let domainSize = document.featureTree.inputDomainSize(
        ofFeature: targetID,
        sourceSize: document.imageSize
      )
    {
      return CropEditingState(
        cropFeature: targetCrop,
        imageSize: domainSize
      )
    }

    return CropEditingState(
      cropFeature: document.displayCrop,
      imageSize: document.imageSize
    )
  }

  /// Extra canvas coverage on every side, as a fraction of the viewport, added
  /// while the canvas rides the zoom bounce. At fit the rendered content sits
  /// flush against the canvas edges; the bounce's zoom + offset spring can then
  /// shift content past an edge, clipping it (the "right edge disappears"
  /// artifact). The overscan renders a margin of extra content so the spring
  /// has slack. Bounded by iOS rubber-banding, so a fixed fraction suffices;
  /// the measured clip was ~6% of the viewport, so 0.25 leaves ample margin
  /// while keeping the transient ride drawable to ~2.25x area.
  private static let zoomBounceRideOverscanFraction: CGFloat = 0.25

  /// - Parameters:
  ///   - forcesModelGeometry: read model layers regardless of the in-flight
  ///     animation state. Used at zoom-bounce-ride start, where the model
  ///     already holds the settled values the ride must land on while the
  ///     presentation is still mid-spring.
  ///   - zoomBounceRideOverscan: expand the canvas beyond the visible viewport
  ///     so the bounce spring cannot shift rendered content past a canvas edge.
  private func makeCropDisplayViewport(
    forcesModelGeometry: Bool = false,
    zoomBounceRideOverscan: Bool = false
  ) -> CropDisplayViewport? {
    guard let crop = state.proposedCrop else {
      return nil
    }

    // A live pinch mutates the scroll view's model values every frame, so
    // presentation layers lag one committed frame behind and sampling them
    // produces a per-frame wobble. The post-release bounce-back is the
    // opposite: UIKit animates the presentation layer while the model has
    // already jumped to the clamped zoom. Sample presentation layers after the
    // pinch ends so the Metal canvas follows the visible bounce instead of
    // snapping to the final model geometry.
    let usesPresentationLayers = forcesModelGeometry == false
      && cropSurface.isInteractiveZoomGestureActive == false
      && isStreamingAdjustmentAngle == false
    var visibleViewportFrame = Self.currentLayerRect(
      bounds,
      from: self,
      to: cropSurface.scrollView,
      usesPresentationLayers: usesPresentationLayers
    )
      .standardized
    guard visibleViewportFrame.width > 0, visibleViewportFrame.height > 0 else {
      return nil
    }

    if zoomBounceRideOverscan {
      visibleViewportFrame = visibleViewportFrame.insetBy(
        dx: -visibleViewportFrame.width * Self.zoomBounceRideOverscanFraction,
        dy: -visibleViewportFrame.height * Self.zoomBounceRideOverscanFraction
      )
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
    let visibleImageRect = crop.imageRect(fromPlatterRect: visiblePlatterRect)
      .intersection(imageBounds)

    guard visibleImageRect.isNull == false, visibleImageRect.isEmpty == false else {
      return nil
    }

    let resolvedVisiblePlatterRect = crop.platterRect(fromImageRect: visibleImageRect)
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

  /// - Parameters: see `makeCropDisplayViewport`.
  private func makeToolCropDisplayViewport(
    forcesModelGeometry: Bool = false,
    zoomBounceRideOverscan: Bool = false
  ) -> CropDisplayViewport? {
    guard let geometry = toolSurface.outputGeometry else {
      return nil
    }

    // Tool mode scrolls the crop-output image directly. During a post-release
    // zoom bounce, UIKit animates the zooming content view's presentation layer
    // while the scroll view's model values are already clamped to the minimum
    // zoom. Derive both the sampled output rect and the canvas placement from
    // layer conversion so the mask canvas follows that visible bounce.
    //
    // Presentation-layer reads are ONLY valid while the viewport display link is
    // actively re-sampling that in-flight bounce. When the tool viewport is
    // applied as a one-shot with the link idle — e.g. entering Blur from Crop,
    // where `updateToolScrollGeometry` just reconfigured the freshly-un-hidden
    // scroll view synchronously in this same runloop turn — the presentation
    // layers still hold the previous session's geometry until the next Core
    // Animation commit. Sampling them then renders the crop output small and
    // pinned to the top-left, and with no display link to re-sample, that stale
    // frame sticks until the next mode switch (the "switch back and forth fixes
    // it" symptom). Fall back to the model layers, which the synchronous
    // reconfigure already made authoritative, whenever the link is idle.
    let usesPresentationLayers = forcesModelGeometry == false
      && toolSurface.viewportRendering.isRunning
      && toolSurface.isInteractiveZoomGestureActive == false
    var canvasFrame = Self.currentLayerRect(
      bounds,
      from: self,
      to: toolSurface.scrollView,
      usesPresentationLayers: usesPresentationLayers
    )
      .standardized
    guard canvasFrame.width > 0, canvasFrame.height > 0 else {
      return nil
    }

    if zoomBounceRideOverscan {
      canvasFrame = canvasFrame.insetBy(
        dx: -canvasFrame.width * Self.zoomBounceRideOverscanFraction,
        dy: -canvasFrame.height * Self.zoomBounceRideOverscanFraction
      )
    }

    let outputBounds = geometry.outputBounds
    let visibleOutputRect = Self.currentLayerRect(
      canvasFrame,
      from: toolSurface.scrollView,
      to: toolSurface.contentView,
      usesPresentationLayers: usesPresentationLayers
    )
      .standardized
      .intersection(outputBounds)

    guard visibleOutputRect.isNull == false, visibleOutputRect.isEmpty == false else {
      return nil
    }

    let visibleScrollRect = Self.currentLayerRect(
      visibleOutputRect,
      from: toolSurface.contentView,
      to: toolSurface.scrollView,
      usesPresentationLayers: usesPresentationLayers
    )
      .standardized
    let visibleCanvasFrame = visibleScrollRect.offsetBy(
      dx: -canvasFrame.minX,
      dy: -canvasFrame.minY
    )
    let zoomScale = max(
      min(
        visibleCanvasFrame.width / max(visibleOutputRect.width, 0.0001),
        visibleCanvasFrame.height / max(visibleOutputRect.height, 0.0001)
      ),
      0.0001
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
    _ crop: CropEditingState,
    previousCrop: CropEditingState? = nil,
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
  private func updateProposedCrop(_ crop: CropEditingState) -> Bool {
    guard state.proposedCrop != crop else {
      return false
    }

    state.proposedCrop = crop

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

  private func applyCropToDocumentIfRenderingChanged(_ crop: CropEditingState) {
    let targetID = featureFocus.cropTargetID ?? crop.id
    var feature = crop.makeCropFeature()
    feature.id = targetID
    guard let currentCrop = document.snapshot?.cropFeature(id: targetID) else {
      document.updateCropFeature(id: targetID, with: feature)
      return
    }

    guard
      currentCrop.isRenderingEquivalent(to: feature, orientedImageSize: crop.imageSize) == false
    else {
      return
    }

    document.updateCropFeature(id: targetID, with: feature)
  }

  private func updateCropLayout(
    previousCrop: CropEditingState? = nil,
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
      // The resolved image-space brush depends on the view bounds; re-resolve
      // in the same layout pass so a stroke cannot begin with a stale width.
      refreshCanvasBrushIfNeeded()
    }

    #if DEBUG
    surfaceHost.platterView.layer.addSublayer(_debug_shapeLayer)
    #endif

    updateCropDisplayViewport()
    updateToolCropDisplayViewport()
  }

  private func updateScrollContainerView(
    by crop: CropEditingState,
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
              self.setCropGuideVisibility(isVisible: self.featureFocus.isCropEditing)
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

  private func updateScrollViewInset(crop: CropEditingState) {
    cropSurface.scrollView.contentInset = makeScrollViewInset(
      aggregatedRotaion: crop.aggregatedRotation.radians
    )
  }

  private func updateToolScrollGeometry(
    crop: CropEditingState,
    syncsViewportFromCropSurface: Bool = false
  ) {
    let displayCrop = toolDisplayCrop(from: crop)
    guard let geometry = EditingCanvasCropOutputGeometry(crop: displayCrop) else {
      return
    }

    let contentSize = geometry.outputSize
    let isContentSizeChanged = toolSurface.contentView.bounds.size != contentSize
    let shouldResetToolSurface = syncsViewportFromCropSurface
      || isContentSizeChanged
      || toolSurface.crop?.isRenderingEquivalent(to: displayCrop) != true

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

    // Static centering inset — the Tool analog of the crop surface's
    // guide-derived inset, with the fitted crop-output box playing the role of
    // the guide (the crop frame IS the tool viewport, see
    // docs/vision-of-editing.md). Like the crop surface, this is written only
    // from layout paths and NEVER from scroll delegate ticks: UIKit derives
    // each interactive tick's contentOffset against the current insets, so any
    // per-tick inset rewrite leaves the gesture running against one-tick-stale
    // geometry — the content tracks visibly off during a pinch and snaps to
    // the reconciled position at release. With constant insets the scroll
    // model is self-consistent through pinch, rubber-band, and bounce. The fit
    // box has the content's own aspect ratio, so at minimum zoom the valid
    // offset range degenerates to the centered point in both axes (content
    // rests centered with no correction); zoomed in, panning clamps at the fit
    // box edges just as crop clamps at the guide; a below-fit pinch
    // rubber-bands freely and bounces back onto the same centered point.
    let fitSize = CGSize(
      width: contentSize.width * minZoomScale,
      height: contentSize.height * minZoomScale
    )
    let horizontalInset = max((toolFrame.width - fitSize.width) / 2, 0)
    let verticalInset = max((toolFrame.height - fitSize.height) / 2, 0)
    toolSurface.scrollView.contentInset = UIEdgeInsets(
      top: verticalInset,
      left: horizontalInset,
      bottom: verticalInset,
      right: horizontalInset
    )

    if shouldResetToolSurface {
      // Tool mode displays the crop output as its own image. Entering Tool mode
      // resets navigation to the fitted crop-output viewport rather than copying
      // Crop mode's source-image pan and rotation state.
      toolSurface.scrollView.setZoomScale(minZoomScale, animated: false)
      toolSurface.crop = displayCrop
      toolSurface.outputGeometry = geometry
      resetToolScrollViewContentOffset()
    } else if toolSurface.scrollView.zoomScale < toolSurface.scrollView.minimumZoomScale {
      toolSurface.scrollView.setZoomScale(toolSurface.scrollView.minimumZoomScale, animated: false)
      toolSurface.outputGeometry = geometry
      resetToolScrollViewContentOffset()
    } else if toolSurface.scrollView.zoomScale > toolSurface.scrollView.maximumZoomScale {
      toolSurface.scrollView.setZoomScale(toolSurface.scrollView.maximumZoomScale, animated: false)
      toolSurface.outputGeometry = geometry
      resetToolScrollViewContentOffset()
    } else {
      toolSurface.outputGeometry = geometry
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
  private func record() -> CropEditingState? {

    // Crop recording only applies while the focus edits a crop node. In
    // masking/viewing focuses the scroll view is a free pan/zoom viewport and
    // must not mutate the crop extent.
    guard featureFocus.isCropEditing else {
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
    currentCrop: CropEditingState
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
    currentCrop: CropEditingState
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
    // Check the bounce BEFORE the interactive-pinch guard: when one finger
    // stays down after a pinch, the pinch recognizer remains .changed while
    // UIKit already runs the zoom bounce-back, so the guard below would snap
    // the canvas to model geometry mid-bounce (the 2-fingers→1 flicker). The
    // bounce state is authoritative regardless of the recognizer.
    if cropSurface.scrollView.isZoomBouncing {
      beginZoomBounceRide(for: .crop)
      return
    }

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
    if toolSurface.scrollView.isZoomBouncing {
      beginZoomBounceRide(for: .tool)
      return
    }

    keepViewportRenderingAlive(for: .tool)

    if toolSurface.viewportRendering.isRunning == false {
      updateToolCropDisplayViewport()
    }
  }

  /// Starts carrying the canvas through the zoom bounce-back on UIKit's own
  /// presentation animation.
  ///
  /// At bounce start the scroll view's model has already jumped to the clamped
  /// final values and emits no further delegate ticks, so: render the final
  /// viewport once from model geometry, then parent the canvas into the
  /// zooming view whose layer is running the bounce spring. The display link
  /// keeps ticking only to detect when the presentation settles; it does not
  /// re-place or re-render the canvas.
  private func beginZoomBounceRide(for surface: ViewportRenderingSurface) {
    let canvasSurface = canvasSurfaceBase(for: surface)
    guard canvasSurface.isRidingZoomBounce == false else {
      return
    }
    guard canRenderViewport(for: surface) else {
      return
    }

    let viewport: CropDisplayViewport?
    switch surface {
    case .crop:
      viewport = makeCropDisplayViewport(
        forcesModelGeometry: true,
        zoomBounceRideOverscan: true
      )
    case .tool:
      viewport = makeToolCropDisplayViewport(
        forcesModelGeometry: true,
        zoomBounceRideOverscan: true
      )
    }
    guard let viewport else {
      return
    }

    // applyViewport writes the canvas frame; inside the bounce-start delegate
    // callback that write would otherwise inherit UIKit's animation context.
    UIView.performWithoutAnimation {
      canvasSurface.applyViewport(viewport)
    }
    canvasSurface.beginZoomBounceRide()
    beginViewportRendering(for: surface)
  }

  private func canvasSurfaceBase(for surface: ViewportRenderingSurface) -> CanvasSurface {
    switch surface {
    case .crop:
      return cropSurface
    case .tool:
      return toolSurface
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
    canvasSurfaceBase(for: surface).endZoomBounceRide()

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

    let canvasSurface = canvasSurfaceBase(for: surface)

    // Delegate callbacks are not guaranteed to observe `isZoomBouncing == true`
    // at bounce start (the flag may flip after they return), so the running
    // display link is the reliable detector: the first tick inside the bounce
    // window hands the canvas over to the ride. Falls through to the chase
    // when the handover is not possible. Gate on the scroll view's actual
    // zooming state, not the pinch recognizer — the recognizer stays .changed
    // for as long as one finger remains down after the pinch.
    if canvasSurface.isRidingZoomBounce == false,
       canvasSurface.scrollView.isZoomBouncing,
       canvasSurface.scrollView.isZooming == false
    {
      beginZoomBounceRide(for: surface)
    }

    if canvasSurface.isRidingZoomBounce {
      // The canvas is riding UIKit's bounce presentation animation inside the
      // zooming view; there is nothing to chase. Detach when the spring
      // settles, or immediately when a real new pinch (isZooming, not the
      // lingering recognizer) grabs the bounce so the model-driven interactive
      // path takes over. A single remaining finger may pan during the ride;
      // the canvas is content-parented, so the pan carries it correctly.
      if canvasSurface.scrollView.isZooming {
        stopViewportRendering(for: surface, appliesViewport: false)
      } else if canvasSurface.scrollView.isZoomBouncing == false,
                isViewportPresentationSettled(for: surface)
      {
        stopViewportRendering(for: surface)
      }
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
    guard
      isDragging == false,
      isTracking == false,
      isDecelerating == false,
      isZooming == false,
      isZoomBouncing == false
    else {
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
      let unclampedTargetScale = min(minXScale, minYScale)
      let targetScale = min(
        max(unclampedTargetScale, minimumZoomScale),
        maximumZoomScale
      )
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

extension CropView: UIGestureRecognizerDelegate {

  /// Updates which FeatureTree point is previewed and which feature node
  /// canvas gestures edit.
  func setFeatureFocus(_ focus: CropViewFeatureFocus) {
    guard featureFocus != focus else {
      return
    }

    let wasCropEditing = featureFocus.isCropEditing
    let previousSeedEffect = resolvedMaskSeedEffect(of: featureFocus)
    let previousViewingIncludedFinalCrop = viewingPointIncludesFinalCrop
    let leavesCropEditing = wasCropEditing && focus.isCropEditing == false
    if leavesCropEditing {
      // Leaving crop editing commits the currently visible crop viewport before
      // the tool surface derives its display geometry.
      applyDocumentChanges()
    }

    featureFocus = focus

    if previousSeedEffect?.editingCanvasEffectIdentity != resolvedMaskSeedEffect(of: focus)?.editingCanvasEffectIdentity {
      document.resetMaskLayerTracking()
    }
    if let layerID = focus.maskTargetLayerID {
      document.adoptMaskLayer(id: layerID)
    }

    // The tool surface needs a geometry re-sync when entering it from crop
    // editing, and also when the viewing point crosses the final crop while
    // staying on the tool surface (output domain <-> pre-crop domain).
    let crossesFinalCrop = focus.isCropEditing == false
      && previousViewingIncludedFinalCrop != viewingPointIncludesFinalCrop

    applySurfaceMode(syncsToolViewportFromCrop: leavesCropEditing || crossesFinalCrop)
    updateCurrentDocumentDisplay()
  }

  func setMaskingBrush(_ brush: CropViewMaskingBrush) {
    guard maskingBrush != brush else {
      return
    }
    maskingBrush = brush
    refreshCanvasBrushIfNeeded()
  }

  /// The masking brush resolved into pre-final-crop image pixels using the
  /// view's current geometry. Mirrors the tool surface's minimum-zoom fit;
  /// `contentInset` does not participate there.
  private var canvasBrush: EditingCanvasBrush {
    let imageDiameter: CGFloat
    switch maskingBrush.diameter {
    case .imagePixels(let value):
      imageDiameter = value
    case .viewportPoints(let value):
      imageDiameter = CropViewMaskingDefaults.imageSpaceBrushDiameter(
        pointDiameter: value,
        viewportSize: bounds.size,
        crop: document.snapshot?.featureTree.finalCrop
      )
    }
    return .init(
      size: Double(imageDiameter),
      hardness: maskingBrush.hardness,
      opacity: maskingBrush.opacity,
      spacing: maskingBrush.spacing
    )
  }

  /// Re-pushes the resolved image-space brush when the host brush or the
  /// geometry it resolves against (crop, bounds) has changed.
  private func refreshCanvasBrushIfNeeded() {
    let resolved = canvasBrush
    guard appliedCanvasBrush != resolved else {
      return
    }
    appliedCanvasBrush = resolved
    cropSurface.configureCanvas(brush: resolved, smoothing: canvasStrokeSmoothing)
    toolSurface.configureCanvas(brush: resolved, smoothing: canvasStrokeSmoothing)
  }

  func setCanvasStrokeSmoothing(_ smoothing: EditingCanvasStrokeSmoothingConfiguration) {
    guard canvasStrokeSmoothing != smoothing else {
      return
    }
    canvasStrokeSmoothing = smoothing
    let resolved = canvasBrush
    appliedCanvasBrush = resolved
    cropSurface.configureCanvas(brush: resolved, smoothing: smoothing)
    toolSurface.configureCanvas(brush: resolved, smoothing: smoothing)
  }

  /// Applies the active surface's visibility, interaction, and viewport wiring.
  ///
  /// - Parameter syncsToolViewportFromCrop: Pass true when transitioning from
  ///   Crop mode into a Tool mode so viewport-only crop scroll changes are not
  ///   mistaken for reusable Tool scroll state.
  private func applySurfaceMode(syncsToolViewportFromCrop: Bool = false) {
    let isCropMode = featureFocus.isCropEditing
    let isDrawingEnabled = featureFocus.isMaskEditing

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
    document: CropViewDocumentSnapshot,
    crop: CropEditingState
  ) {
    guard featureFocus.isCropEditing else {
      cropSurface.hideCanvasView()
      return
    }

    // Editing a repeated crop upstream of the final crop shows that crop's input
    // domain — every upstream feature evaluated into one image — so the guide
    // frames the already-cropped result rather than the full source. nil keeps
    // the final-crop path on the existing source-plus-effects preview.
    let targetID = featureFocus.cropTargetID
    let inputDomainImage = document.cropEditingInputImage(forTarget: targetID)
    let inputDomainFeatures = document.cropEditingInputFeatures(forTarget: targetID) ?? []

    cropSurface.updateRenderedEditPreview(
      document: document,
      crop: crop,
      inputDomainImage: inputDomainImage,
      inputDomainFeatures: inputDomainFeatures
    )
  }

  fileprivate func commitCanvasStroke(
    record: EditingCanvasStrokeRecord,
    completion: @escaping () -> Void
  ) {
    let committedRecord: EditingCanvasStrokeRecord
    if
      featureFocus.isCropEditing == false,
      let crop = state.proposedCrop,
      let geometry = makeToolOutputGeometry(crop: crop)
    {
      committedRecord = geometry.sourceRecord(fromOutputRecord: record)
    } else {
      committedRecord = record
    }

    appendRecordToDocument(committedRecord)
    syncCommittedStrokesFromDocument()
    completion()
  }

  /// The seed effect for the given focus, defaulting to the standard blur
  /// pipeline when mask editing without an explicit seed. The default lives
  /// here — not in the hosts — because the seed is a document parameter
  /// (the exported effect strength), frozen into the layer at first stroke.
  private func resolvedMaskSeedEffect(
    of focus: CropViewFeatureFocus
  ) -> EffectPipeline? {
    guard focus.isMaskEditing else {
      return nil
    }
    if let explicit = focus.maskSeedEffect {
      return explicit
    }
    return CropViewMaskingDefaults.blurEffectPipeline
  }

  private var resolvedMaskSeedEffect: EffectPipeline? {
    resolvedMaskSeedEffect(of: featureFocus)
  }

  private func appendRecordToDocument(_ record: EditingCanvasStrokeRecord) {
    guard
      let currentLocalEffect = resolvedMaskSeedEffect,
      let insertionAnchor = featureFocus.maskInsertionAnchor
    else {
      return
    }

    document.appendMaskStroke(
      record: record,
      effect: currentLocalEffect,
      insertingBefore: insertionAnchor
    )
  }

  /// The effect persisted on the committed editing-canvas layer, if one exists.
  ///
  /// Document parameters are frozen at layer creation. The focus's seed effect
  /// may drift afterwards (the default blur seed derives from the current
  /// crop), so already-painted layers must not be rewritten to match it.
  private func committedCanvasLocalEffect() -> EffectPipeline? {
    guard let currentLocalEffect = resolvedMaskSeedEffect else {
      return nil
    }

    return document.committedMaskEffect(matching: currentLocalEffect)
  }

  private func syncCommittedStrokesFromDocument() {
    let sourceRecords = currentSourceCommittedStrokes()
    cropSurface.setCommittedStrokes(sourceRecords)

    guard
      let crop = state.proposedCrop,
      let geometry = makeToolOutputGeometry(crop: crop)
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
    document.committedMaskRecords(matching: resolvedMaskSeedEffect)
  }
}
