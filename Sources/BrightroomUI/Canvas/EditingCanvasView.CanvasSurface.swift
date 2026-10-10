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

import UIKit
import MetalKit

import BrightroomEngine
import BrightroomParametric

extension EditingCanvasView {

  /// Drives the fixed canvas for the lifetime of the visible editor.
  ///
  /// The run loop retains this proxy, not the editor. Gesture boundaries never
  /// start or stop the link: every displayed frame samples the scroll geometry,
  /// while the canvas submits Metal work only when its input changes.
  @MainActor
  final class ViewportDisplayLink: NSObject {
    weak var owner: EditingCanvasView?
    private var displayLink: CADisplayLink?

    func start(maximumFramesPerSecond: Int) {
      if displayLink == nil {
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
      }
      let maximum = Float(maximumFramesPerSecond)
      displayLink?.preferredFrameRateRange = .init(
        minimum: min(60, maximum), maximum: maximum, preferred: maximum
      )
    }

    func invalidate() {
      displayLink?.invalidate()
      displayLink = nil
    }

    isolated deinit {
      invalidate()
    }

    @objc private func tick(_ link: CADisplayLink) {
      guard let owner else {
        invalidate()
        return
      }
      owner.drawViewportFrame()
    }
  }

  /// Owns the shared UIKit view graph that hosts the crop and tool surfaces.
  ///
  /// The platter is shared because crop and tool scroll views are siblings under
  /// the same clipping and mask plane. It should not be owned by either surface.
  @MainActor
  final class SurfaceHost {
    let platterView = UIView()
    let backdropView = UIView()
    /// An untransformed sibling of the scroll hierarchy. Metal never moves
    /// with a scroll view; its pixels are placed by the sampled affine mapping.
    let canvasHostView = UIView()
    let canvasClipLayer = CAShapeLayer()
    private var displayedClipRect: CGRect?

    /// Applies sampled clipping without rebuilding an unchanged path or causing
    /// another Core Animation transaction while the canvas is stationary.
    func updateCanvasClip(_ rect: CGRect?) {
      guard let rect else {
        if canvasHostView.layer.mask != nil {
          canvasHostView.layer.mask = nil
        }
        displayedClipRect = nil
        return
      }
      guard displayedClipRect != rect
        || canvasClipLayer.frame != canvasHostView.bounds
        || canvasHostView.layer.mask !== canvasClipLayer else { return }

      CATransaction.begin()
      CATransaction.setDisableActions(true)
      canvasClipLayer.frame = canvasHostView.bounds
      canvasClipLayer.path = UIBezierPath(rect: rect).cgPath
      canvasHostView.layer.mask = canvasClipLayer
      CATransaction.commit()
      displayedClipRect = rect
    }
  }

  /// The post-crop pass of one displayed frame: the effect the feature
  /// evaluates after its final crop, and where the crop output lies on the
  /// canvas. See `EditingCanvasRenderer.setPostCrop(effect:frame:chainEntry:)`.
  struct CanvasPostCrop: Equatable {
    let effect: AnyImageEffect
    /// The crop output on the canvas, in canvas points.
    let frame: CGRect
    /// The whole source in the surface's content coordinates.
    let chainEntry: CGRect

    /// The pass on a tool surface, whose content is the crop output: the
    /// frame is the content's bounds where the viewport places them.
    init?(
      effect: AnyImageEffect?,
      geometry: EditingCanvasCropOutputGeometry,
      viewport: CanvasViewport
    ) {
      guard let effect else { return nil }
      self.effect = effect
      self.frame = geometry.outputBounds.applying(viewport.contentToCanvasTransform)
      self.chainEntry = CGRect(origin: .zero, size: geometry.sourceImageSize)
        .applying(geometry.inputToOutputTransform)
    }

    /// The pass on the crop surface, whose content is the source: the crop
    /// output is what the crop guide frames.
    ///
    /// - Parameter guideFrame: The crop guide on the canvas, sampled with the
    ///   viewport of the same frame.
    init?(effect: AnyImageEffect?, guideFrame: CGRect, imageSize: CGSize) {
      guard let effect else { return nil }
      self.effect = effect
      self.frame = guideFrame
      self.chainEntry = CGRect(origin: .zero, size: imageSize)
    }
  }

  /// Common core shared by the Crop and Tool surfaces: a UIScrollView that
  /// owns pan/zoom physics over a transparent zooming view. The Metal canvas
  /// lives in the fixed host coordinate space, outside the scroll hierarchy.
  ///
  /// These are reference types because UIKit may re-enter scroll-view delegate
  /// callbacks while a surface is updating its views and layers.
  class CanvasSurface: NSObject, UIScrollViewDelegate {
    let scrollView = CropScrollView()
    var canvasView: EditingCanvasMTKView?
    var canvasSize: CGSize?
    /// The mapping of the last frame submitted for display, also used to
    /// map drawing gestures back into the surface's editing domain.
    var displayedViewport: CanvasViewport?

    /// The transparent view the scroll view zooms to produce navigation geometry.
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

    init(zoomingView: UIView) {
      self.zoomingView = zoomingView
      super.init()
      scrollView.delegate = self
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

    @discardableResult
    func ensureCanvasView(
      in hostView: UIView,
      canvasSize: CGSize,
      brush: EditingCanvasBrush,
      smoothing: ImageEditorCanvas.Brush.Smoothing,
      onStrokeCommit: @escaping CanvasStrokeCommitHandler
    ) -> EditingCanvasMTKView? {
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

      let view = EditingCanvasMTKView(canvasSize: canvasSize, device: device)
      view.isUserInteractionEnabled = false
      view.isHidden = true
      view.configure(brush: brush, smoothing: smoothing)
      view.onStrokeCommit = onStrokeCommit
      view.frame = hostView.bounds
      hostView.addSubview(view)
      canvasView = view
      self.canvasSize = canvasSize
      return view
    }

    func removeCanvasView() {
      displayedViewport = nil
      canvasView?.removeFromSuperview()
      canvasView = nil
      canvasSize = nil
    }

    func hideCanvasView() {
      canvasView?.isHidden = true
    }

    func configureCanvas(
      brush: EditingCanvasBrush,
      smoothing: ImageEditorCanvas.Brush.Smoothing
    ) {
      canvasView?.configure(brush: brush, smoothing: smoothing)
    }

    func setCommittedStrokes(_ records: [EditingCanvasStrokeRecord]) {
      canvasView?.setCommittedStrokes(records)
    }

    /// Samples the viewport and submits a changed frame without moving the canvas.
    ///
    /// - Parameter postCrop: The pass drawn after the crop, sampled with
    ///   `viewport`, or nil when the feature has none.
    func draw(viewport: CanvasViewport?, postCrop: CanvasPostCrop?) {
      guard let canvasView else { return }
      displayedViewport = viewport
      guard let viewport else {
        canvasView.isHidden = true
        return
      }
      canvasView.isHidden = false
      if canvasView.contentScaleFactor != viewport.contentScaleFactor {
        canvasView.contentScaleFactor = viewport.contentScaleFactor
      }
      canvasView.setViewport(viewport.editingCanvasViewport)
      canvasView.setPostCrop(
        effect: postCrop?.effect,
        frame: postCrop?.frame ?? .null,
        chainEntry: postCrop?.chainEntry ?? .null
      )
      canvasView.drawIfNeeded()
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
  /// is a viewing window over the feature with its crop neutralized, so the
  /// global effects and the blur mask stay visible while choosing the crop.
  final class CropSurface: CanvasSurface {

    let imagePlatterView: ImagePlatterView
    var currentCanvasInputKey: CanvasInputKey?

    init() {
      let platterView = ImagePlatterView()
      self.imagePlatterView = platterView
      super.init(zoomingView: platterView)
    }

    override func removeCanvasView() {
      super.removeCanvasView()
      currentCanvasInputKey = nil
    }

    func updateRenderedEditPreview(
      source: EditingCanvasSource,
      feature: ImageEditorFeature,
      crop: CropGuideState,
      committedStrokes: @autoclosure () -> [EditingCanvasStrokeRecord]
    ) {
      guard crop.imageSize == canvasSize, let canvasView else {
        return
      }

      let key = CanvasInputKey(source: source, feature: feature, crop: crop)
      guard currentCanvasInputKey != key || canvasView.hasRenderImages == false else {
        canvasView.isHidden = false
        return
      }

      let renderPlan = CanvasRenderPlan(localBlur: feature.localBlur)
      guard
        let images = EditingCanvasRenderImageFactory.makeRenderImages(
          editingSourceImage: source.editingSourceImage,
          effects: feature.effects.canvasEffect,
          canvasSize: crop.imageSize,
          mode: renderPlan.canvasMode
        )
      else {
        return
      }

      canvasView.setRenderImages(images)
      // This canvas is sized to crop.imageSize, so the records are in the
      // source domain.
      canvasView.setCommittedStrokes(committedStrokes())
      canvasView.isHidden = false
      currentCanvasInputKey = key
    }

    func applyMode(isActive: Bool) {
      scrollView.isScrollEnabled = isActive
      scrollView.pinchGestureRecognizer?.isEnabled = isActive
      scrollView.isHidden = !isActive
    }

    /// The ratio of `to`'s diagonal to `from`'s diagonal.
    private static func diagonalRatio(to: CGSize, from: CGSize) -> CGFloat {
      let fromDiagonal = sqrt(pow(from.height, 2) + pow(from.width, 2))
      let toDiagonal = sqrt(pow(to.height, 2) + pow(to.width, 2))
      return toDiagonal / fromDiagonal
    }

    func remainingScroll(
      guideRectInPlatter: CGRect,
      guideSize: CGSize,
      crop: CropGuideState
    ) -> UIEdgeInsets {
      let scale = Self.diagonalRatio(to: guideSize, from: guideRectInPlatter.size)
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
  /// in that crop-output coordinate space, then `EditingCanvasView` maps the committed
  /// stroke back into the pre-crop Feature domain before saving it.
  final class ToolSurface: CanvasSurface {

    /// Inputs that determine the output of
    /// `EditingCanvasRenderImageFactory.makeCropOutputRenderImages`. The source
    /// image is compared by identity; `EditingCanvasSource` stores it as an
    /// immutable property, so a new editing source always produces a new
    /// instance. Strokes are not part of the key: committing one keeps the
    /// render images and their bakes.
    struct CanvasRenderInputKey: Equatable {
      var sourceImage: ObjectIdentifier
      var effects: ImageEditorFeature.Effects
      var geometry: EditingCanvasCropOutputGeometry
      var mode: EditingCanvasMode
    }

    let contentView: UIView
    let drawingGestureRecognizer = EditingCanvasDrawingGestureRecognizer(target: nil, action: nil)
    /// A memo of the crop that produced the currently published
    /// `outputGeometry`.
    ///
    /// This is not the surface's primary state and nothing renders from it: it
    /// exists so the scroll-geometry pass can detect that the crop changed and
    /// reset tool navigation.
    var lastAppliedCrop: CropGuideState?

    /// The geometry that the next render and viewport read use.
    ///
    /// Published only through `publishOutputGeometry(_:)` (plus the teardown in
    /// `removeCanvasView`), so the write sites stay greppable and the ordering
    /// rule lives in one place.
    private(set) var outputGeometry: EditingCanvasCropOutputGeometry?

    var currentCanvasRenderInputKey: CanvasRenderInputKey?

    init() {
      let view = UIView()
      view.backgroundColor = .clear
      view.isOpaque = false
      view.accessibilityIdentifier = "toolSurfaceContentView"
      self.contentView = view
      super.init(zoomingView: view)
    }

    override func removeCanvasView() {
      super.removeCanvasView()
      lastAppliedCrop = nil
      outputGeometry = nil
      currentCanvasRenderInputKey = nil
    }

    /// Publishes the geometry that the next render and viewport read use.
    ///
    /// This is the single publish path for `outputGeometry`. Both writers —
    /// `EditingCanvasView.updateToolScrollGeometry` and this surface's own
    /// `updateCanvas` — funnel through here, and both derive the value from
    /// the proposed crop; that shared derivation is what keeps the two call
    /// sites consistent.
    ///
    /// Ordering contract: publish BEFORE any zoom write so reentrant UIKit
    /// callbacks and the next display frame observe the same output domain.
    func publishOutputGeometry(_ geometry: EditingCanvasCropOutputGeometry) {
      outputGeometry = geometry
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
      source: EditingCanvasSource,
      effects: ImageEditorFeature.Effects,
      geometry: EditingCanvasCropOutputGeometry,
      mode: EditingCanvasMode,
      committedStrokes: [EditingCanvasStrokeRecord]
    ) {
      guard geometry.outputSize == canvasSize, let canvasView else {
        return
      }
      publishOutputGeometry(geometry)

      let inputKey = CanvasRenderInputKey(
        sourceImage: ObjectIdentifier(source.editingSourceImage),
        effects: effects,
        geometry: geometry,
        mode: mode
      )

      // Hosts call this on every state update (stroke commits, brush changes,
      // unrelated SwiftUI re-renders). Rebuilding identical render-image graphs
      // would discard the canvas's viewport texture caches each time.
      if currentCanvasRenderInputKey != inputKey || canvasView.hasRenderImages == false {
        guard
          let images = EditingCanvasRenderImageFactory.makeCropOutputRenderImages(
            editingSourceImage: source.editingSourceImage,
            effects: effects.canvasEffect,
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
}
