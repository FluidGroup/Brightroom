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

#if os(iOS)

import UIKit
import MetalKit

import BrightroomEngine
import BrightroomParametric

extension EditingCanvasView {

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

  /// Common core shared by the Crop and Tool surfaces: a UIScrollView that
  /// owns pan/zoom physics over a transparent zooming view. The Metal canvas
  /// lives in the fixed host coordinate space, outside the scroll hierarchy;
  /// `CanvasMetalSurface` owns it and draws it.
  ///
  /// These are reference types because UIKit may re-enter scroll-view delegate
  /// callbacks while a surface is updating its views and layers.
  class CanvasSurface: CanvasMetalSurface, UIScrollViewDelegate {
    let scrollView = CropScrollView()

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
      guard geometry.outputSize == canvasSize, canvasView != nil else {
        return
      }
      publishOutputGeometry(geometry)

      updateCropOutput(
        source: source,
        effects: effects,
        geometry: geometry,
        mode: mode,
        committedStrokes: committedStrokes,
        key: &currentCanvasRenderInputKey
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

    var zoomedContentSize: CGSize {
      let contentSize = outputGeometry?.outputSize ?? contentView.frame.size
      return CGSize(
        width: contentSize.width * scrollView.zoomScale,
        height: contentSize.height * scrollView.zoomScale
      )
    }

  }
}

#endif
