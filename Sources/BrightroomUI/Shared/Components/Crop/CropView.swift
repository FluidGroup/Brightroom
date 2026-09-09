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

  typealias CanvasStrokeCommitHandler = (
    EditingCanvasStrokeRecord,
    @escaping () -> Void
  ) -> Void

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

  private let viewportDisplayLink = ViewportDisplayLink()
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

    surfaceHost.canvasHostView.isUserInteractionEnabled = false
    surfaceHost.canvasHostView.clipsToBounds = true
    surfaceHost.canvasHostView.accessibilityIdentifier = "CropView.fixedCanvasHost"
    addSubview(surfaceHost.canvasHostView)

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
        guard let contentPoint = self.toolContentPoint(from: point) else { return }
        self.toolSurface.beginStroke(at: contentPoint)
      }
      toolSurface.drawingGestureRecognizer.onMove = { [weak self] points in
        guard let self else { return }
        self.toolSurface.appendStroke(points: points.compactMap(self.toolContentPoint(from:)))
      }
      toolSurface.drawingGestureRecognizer.onEnd = { [weak self] point in
        guard let self else { return }
        guard let contentPoint = self.toolContentPoint(from: point) else {
          self.toolSurface.cancelStroke()
          return
        }
        self.toolSurface.endStroke(at: contentPoint)
        // Stroke end is a quiet moment: if an interrupted pinch left the
        // scroll model outside its valid range, recover it here.
        self.settleToolScrollInsetIfNeeded()
      }
      toolSurface.drawingGestureRecognizer.onCancel = { [weak self] in
        self?.toolSurface.cancelStroke()
      }
    }

    cropSurface.scrollView.addSubview(cropSurface.imagePlatterView)

    toolSurface.contentView.isUserInteractionEnabled = true
    toolSurface.scrollView.isHidden = true
    // The shared _ScrollView defaults enable alwaysBounce for the crop
    // surface, where over-dragging past the guide is how the user nudges the
    // crop composition. The tool surface has no such semantics: its offset
    // range degenerates to a point at fit zoom, and alwaysBounce would let a
    // two-finger drag carry the whole photo out of the fitted viewport with
    // nothing anchoring it visually.
    toolSurface.scrollView.alwaysBounceVertical = false
    toolSurface.scrollView.alwaysBounceHorizontal = false
    // `bounces` stays at UIKit's default (true). It gates the offset freedom
    // during an active pinch: with it off, a below-minimum pinch hard-clamps
    // the offset to the degenerate range and the photo shrinks pinned to the
    // fit box's top-left corner instead of around the fingers. The
    // resting-displacement class this flag was once disabled for is guarded
    // structurally now — `settleToolScrollInsetIfNeeded` reconciles UIKit's
    // stale contentSize after a below-minimum pinch and glides any
    // out-of-range rest back into the covering range at quiet boundaries.
    toolSurface.scrollView.addSubview(toolSurface.contentView)
    addGestureRecognizer(toolSurface.drawingGestureRecognizer)

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

    viewportDisplayLink.owner = self
    NotificationCenter.default.addObserver(
      self, selector: #selector(updateViewportDisplayLink),
      name: UIApplication.didBecomeActiveNotification, object: nil
    )
    NotificationCenter.default.addObserver(
      self, selector: #selector(updateViewportDisplayLink),
      name: UIApplication.didEnterBackgroundNotification, object: nil
    )

    scrollEventHandlers: do {
      cropSurface.onDidZoom = { [weak self] in
        guard let self else { return }
        self.debugLogScrollViewAdjustment("did-zoom")

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
      }
      cropSurface.onDidEndDecelerating = { [weak self] in
        guard let self else { return }
        self.debugLogScrollViewAdjustment("deceleration-end")
        self.endScrollViewAdjustment(.drag)
      }

      toolSurface.onDidEndDragging = { [weak self] _ in
        guard let self else { return }
        self.settleToolScrollInsetIfNeeded()
      }
      toolSurface.onDidEndZooming = { [weak self] _ in
        guard let self else { return }
        // The pinch ran on the inset captured at its start; reconcile it to
        // the settled zoom scale so the offset glides back into the covering
        // range. Deferred one runloop tick: inside this callback
        // `isZoomBouncing` is not reliably observable yet (it may flip after
        // the delegate returns), and settling against a starting bounce
        // animation fights it — the deferred call sees the flag and skips,
        // leaving the bounce-settle path to reconcile instead.
        DispatchQueue.main.async {
          self.settleToolScrollInsetIfNeeded()
        }
      }
      toolSurface.onDidEndDecelerating = { [weak self] in
        guard let self else { return }
        self.settleToolScrollInsetIfNeeded()
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
    viewportDisplayLink.invalidate()
    NotificationCenter.default.removeObserver(self)
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
        in: surfaceHost.canvasHostView,
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
          in: surfaceHost.canvasHostView,
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

  struct CanvasInputKey: Equatable {
    var imageSize: CGSize
    var sourceImage: ObjectIdentifier
    var sourceExtent: CGRect
    var effects: EffectPipeline
    var localAdjustments: [LocalAdjustmentFeature]

    init(document: CropViewDocumentSnapshot, crop: CropEditingState) {
      let previewSourceImage = document.editingSourceImage.removingExtentOffset()
      self.imageSize = crop.imageSize
      // Extent alone cannot detect a same-size source replacement (the
      // editing source is always capped to the same max pixel size).
      self.sourceImage = ObjectIdentifier(document.editingSourceImage)
      self.sourceExtent = previewSourceImage.extent
      self.effects = document.effects
      self.localAdjustments = document.localAdjustments
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
    return CropEditingState(
      cropFeature: document.displayCrop,
      imageSize: document.imageSize
    )
  }

  /// The layer coordinates sampled together for one displayed frame.
  /// Content placement and guide clipping must use the same animation state.
  private struct DisplayLayers {
    let content: CALayer
    let canvas: CALayer
    let clip: CALayer
  }

  private func hasViewportAnimation(for surface: CanvasSurface) -> Bool {
    if surface.scrollView.isZoomBouncing { return true }
    var ancestor: CALayer? = surface.zoomingView.layer
    while let layer = ancestor, layer !== self.layer {
      if layer.animationKeys()?.isEmpty == false { return true }
      ancestor = layer.superlayer
    }
    return false
  }

  /// Live scroll/pinch values come from the model tree. Bounce, offset settle,
  /// and rotation sample the presentation tree while an animation is present.
  /// Requiring all three layers avoids combining a new model layout with an
  /// old presentation clip after a nonanimated update.
  private func displayLayers(for surface: CanvasSurface) -> DisplayLayers {
    let content = surface.zoomingView.layer
    let canvas = surfaceHost.canvasHostView.layer
    let clip = surfaceHost.platterView.layer
    if hasViewportAnimation(for: surface),
       let contentPresentation = content.presentation(),
       let canvasPresentation = canvas.presentation(),
       let clipPresentation = clip.presentation() {
      return DisplayLayers(
        content: contentPresentation, canvas: canvasPresentation, clip: clipPresentation
      )
    }
    return DisplayLayers(content: content, canvas: canvas, clip: clip)
  }

  /// Converts three content landmarks without discarding rotation through an
  /// enclosing rectangle. The fixed canvas and its drawable retain their size.
  private func makeDisplayViewport(
    for surface: CanvasSurface,
    layers: DisplayLayers,
    contentSize: CGSize,
    contentToZoomingScale: CGFloat
  ) -> CropDisplayViewport? {
    guard contentSize.width > 0, contentSize.height > 0 else { return nil }
    let source = layers.content
    let destination = layers.canvas

    let origin = destination.convert(CGPoint.zero, from: source)
    let horizontal = destination.convert(
      CGPoint(x: contentSize.width * contentToZoomingScale, y: 0), from: source
    )
    let vertical = destination.convert(
      CGPoint(x: 0, y: contentSize.height * contentToZoomingScale), from: source
    )
    let transform = CropDisplayViewport.contentTransform(
      contentSize: contentSize, origin: origin,
      horizontalCorner: horizontal, verticalCorner: vertical
    )
    return CropDisplayViewport(
      contentBounds: CGRect(origin: .zero, size: contentSize),
      canvasBounds: surfaceHost.canvasHostView.bounds,
      contentToCanvasTransform: transform,
      contentScaleFactor: window?.screen.scale ?? traitCollection.displayScale
    )
  }

  /// Gesture coordinates are in the host, independent of the invisible zoom
  /// view. Use the displayed frame's inverse so the brush follows visible pixels
  /// even if UIKit's model is already at the end of a settle animation.
  private func toolContentPoint(from hostPoint: CGPoint) -> CGPoint? {
    guard let viewport = toolSurface.displayedViewport else { return nil }
    return viewport.contentPoint(
      fromCanvasPoint: convert(hostPoint, to: surfaceHost.canvasHostView)
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

    lastLaidOutCrop = crop
  }

  override func layoutSubviews() {
    super.layoutSubviews()

    UIView.performWithoutAnimation {
      surfaceHost.canvasHostView.frame = bounds
      for surface in [cropSurface as CanvasSurface, toolSurface] {
        if let canvasView = surface.canvasView, canvasView.frame != surfaceHost.canvasHostView.bounds {
          canvasView.frame = surfaceHost.canvasHostView.bounds
        }
      }
    }

    // TODO: Get an optimized size
    let screenBounds = window?.screen.bounds ?? UIScreen.main.bounds
    guideOutsideContainerView.frame.size = .init(
      width: screenBounds.width * 1.5,
      height: screenBounds.height * 1.5
    )
    // `center` is expressed in the superview's coordinate space; a subview's
    // center belongs to this view's own bounds space.
    guideOutsideContainerView.center = .init(x: bounds.midX, y: bounds.midY)

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
      || toolSurface.lastAppliedDisplayCrop?.isRenderingEquivalent(to: displayCrop) != true

    // Resolve and validate the frame BEFORE any write so a degenerate layout
    // pass cannot leave the surface half-configured.
    let toolFrame = self
      .convert(bounds, to: surfaceHost.platterView)
      .standardized
    guard toolFrame.width > 0, toolFrame.height > 0 else {
      return
    }

    if isContentSizeChanged {
      // `contentView` is the zoom view; while a zoom transform is applied,
      // `frame` is derived from bounds × transform, so reset the transform
      // first to make the frame write well-defined. A content-size change
      // always flows into the reset branch below, which re-establishes the
      // zoom scale (and with it the transform) from the new fit.
      toolSurface.contentView.transform = .identity
      toolSurface.contentView.frame = CGRect(origin: .zero, size: contentSize)
      toolSurface.scrollView.contentSize = contentSize
    }

    // Skip no-op writes: setting `frame` on a scroll view cancels any running
    // scroll animation (including the settle glide), so only write when the
    // geometry actually changed.
    if toolSurface.scrollView.transform != .identity {
      toolSurface.scrollView.transform = .identity
    }
    if toolSurface.scrollView.frame != toolFrame {
      toolSurface.scrollView.frame = toolFrame
    }

    let minZoomScale = min(
      toolFrame.width / max(contentSize.width, 0.0001),
      toolFrame.height / max(contentSize.height, 0.0001)
    )
    toolSurface.scrollView.minimumZoomScale = minZoomScale
    toolSurface.scrollView.maximumZoomScale = max(minZoomScale * 8, minZoomScale)

    // Publish the output domain before zoom writes so reentrant UIKit callbacks
    // and the next display frame observe the same geometry.
    toolSurface.lastAppliedDisplayCrop = displayCrop
    toolSurface.publishOutputGeometry(geometry)

    if shouldResetToolSurface {
      // Tool mode displays the crop output as its own image. Entering Tool mode
      // resets navigation to the fitted crop-output viewport rather than copying
      // Crop mode's source-image pan and rotation state.
      toolSurface.scrollView.setZoomScale(minZoomScale, animated: false)
      updateToolScrollViewInset()
      resetToolScrollViewContentOffset()
    } else {
      // Layout may be reentered during a pinch or bounce. Keep its geometry
      // until the quiet settle path can animate any zoom/offset correction.
      settleToolScrollInsetIfNeeded()
    }

    if isZoomEnabled == false {
      let scale = toolSurface.scrollView.zoomScale
      toolSurface.scrollView.minimumZoomScale = scale
      toolSurface.scrollView.maximumZoomScale = scale
    }
  }

  /// Writes the tool surface's centering inset for the CURRENT zoom scale:
  /// each axis centers the zoomed content while it is smaller than the
  /// viewport and drops to zero once the content covers it, so the pan clamp
  /// always keeps the photo covering every viewport region it can cover —
  /// no void can come to rest between the photo's edge and the viewport edge
  /// (Photos parity). At minimum zoom this degenerates to the fitted
  /// letterbox inset, where the valid offset range is a single centered
  /// point.
  ///
  /// Like the crop surface's guide inset, this is written only from layout
  /// paths and gesture boundaries, NEVER from didZoom/didScroll ticks: UIKit
  /// derives each interactive tick's contentOffset against the current
  /// insets, so any per-tick inset rewrite leaves the gesture running against
  /// one-tick-stale geometry — the content tracks visibly off during a pinch
  /// and snaps to the reconciled position at release. The price of the static
  /// model is that a continuous pinch runs on the inset captured at its
  /// start; `settleToolScrollInsetIfNeeded` reconciles when the gesture ends.
  private func updateToolScrollViewInset() {
    let scrollView = toolSurface.scrollView
    let viewportSize = scrollView.bounds.size
    let zoomedSize = toolSurface.zoomedContentSize
    let horizontalInset = max((viewportSize.width - zoomedSize.width) / 2, 0)
    let verticalInset = max((viewportSize.height - zoomedSize.height) / 2, 0)
    scrollView.contentInset = UIEdgeInsets(
      top: verticalInset,
      left: horizontalInset,
      bottom: verticalInset,
      right: horizontalInset
    )
  }

  /// Reconciles the tool inset with the settled zoom scale at a quiet moment
  /// and glides the offset into the tightened range. No-op while any touch,
  /// deceleration, or bounce is still in flight — those run on the inset
  /// captured when they began, and the next quiet call reconciles them.
  private func settleToolScrollInsetIfNeeded() {
    let scrollView = toolSurface.scrollView
    guard
      scrollView.isTracking == false,
      scrollView.isDragging == false,
      scrollView.isDecelerating == false,
      scrollView.isZooming == false,
      scrollView.isZoomBouncing == false,
      hasViewportAnimation(for: toolSurface) == false
    else {
      return
    }

    // A cancelled pinch may leave the model outside its valid zoom range.
    // Ask UIKit to animate that recovery; the frame loop follows it and
    // reconciles the inset only after the zoom animation has finished.
    let minZoom = scrollView.minimumZoomScale
    let maxZoom = scrollView.maximumZoomScale
    let clampedZoom = min(max(scrollView.zoomScale, minZoom), maxZoom)
    if abs(clampedZoom - scrollView.zoomScale) > 0.0001 {
      scrollView.setZoomScale(clampedZoom, animated: areAnimationsEnabled)
      return
    }

    let viewportSize = scrollView.bounds.size
    let zoomedSize = toolSurface.zoomedContentSize
    let target = UIEdgeInsets(
      top: max((viewportSize.height - zoomedSize.height) / 2, 0),
      left: max((viewportSize.width - zoomedSize.width) / 2, 0),
      bottom: max((viewportSize.height - zoomedSize.height) / 2, 0),
      right: max((viewportSize.width - zoomedSize.width) / 2, 0)
    )

    let current = scrollView.contentInset
    let tolerance: CGFloat = 0.5

    // A below-minimum pinch can leave UIKit's contentSize larger than the
    // actual zoomed view. Both size and inset writes may clamp contentOffset
    // synchronously, so preserve the position before either write. The
    // animation below owns the visible return into the corrected range.
    let sizeNeedsWrite =
      abs(scrollView.contentSize.width - zoomedSize.width) > tolerance
        || abs(scrollView.contentSize.height - zoomedSize.height) > tolerance
    let insetNeedsWrite =
      abs(current.top - target.top) > tolerance
        || abs(current.left - target.left) > tolerance
        || abs(current.bottom - target.bottom) > tolerance
        || abs(current.right - target.right) > tolerance

    if sizeNeedsWrite || insetNeedsWrite {
      let offset = scrollView.contentOffset
      UIView.performWithoutAnimation {
        if sizeNeedsWrite { scrollView.contentSize = zoomedSize }
        if insetNeedsWrite { scrollView.contentInset = target }
        scrollView.setContentOffset(offset, animated: false)
      }
    }

    // Glide the offset into the valid range, computed from the true zoomed
    // content size. This runs on EVERY quiet settle, not only when the inset
    // changed, so a correction lost to an unrelated scroll-view write is
    // re-issued instead of stranding the content out of range. Driven by
    // UIViewPropertyAnimator (the same pattern as customZoom).
    let offset = scrollView.contentOffset
    let minOffset = CGPoint(x: -target.left, y: -target.top)
    let maxOffset = CGPoint(
      x: zoomedSize.width - scrollView.bounds.width + target.right,
      y: zoomedSize.height - scrollView.bounds.height + target.bottom
    )
    let clamped = CGPoint(
      x: min(max(offset.x, minOffset.x), max(maxOffset.x, minOffset.x)),
      y: min(max(offset.y, minOffset.y), max(maxOffset.y, minOffset.y))
    )
    if abs(clamped.x - offset.x) > tolerance || abs(clamped.y - offset.y) > tolerance {
      let animator = UIViewPropertyAnimator(duration: 0.35, dampingRatio: 1) {
        scrollView.contentOffset = clamped
      }
      animator.startAnimation()
    }
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

  override func didMoveToWindow() {
    super.didMoveToWindow()
    updateViewportDisplayLink()
  }

  @objc private func updateViewportDisplayLink() {
    guard let window, UIApplication.shared.applicationState != .background else {
      viewportDisplayLink.invalidate()
      return
    }
    viewportDisplayLink.start(maximumFramesPerSecond: window.screen.maximumFramesPerSecond)
  }

  /// The only recurring viewport/render entry point for both editing surfaces.
  /// No scroll delegate or settle timer can end this frame sequence.
  func drawViewportFrame() {
    var ancestor: UIView? = self
    while let view = ancestor {
      guard view.isHidden == false, view.alpha > 0 else { return }
      ancestor = view.superview
    }
    guard window != nil, surfaceHost.canvasHostView.bounds.isEmpty == false else { return }

    let surface: CanvasSurface = featureFocus.isCropEditing ? cropSurface : toolSurface
    let layers = displayLayers(for: surface)
    if clipsToGuide {
      let clipRect = layers.canvas.convert(layers.clip.bounds, from: layers.clip)
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      surfaceHost.canvasClipLayer.frame = surfaceHost.canvasHostView.bounds
      surfaceHost.canvasClipLayer.path = UIBezierPath(rect: clipRect).cgPath
      surfaceHost.canvasHostView.layer.mask = surfaceHost.canvasClipLayer
      CATransaction.commit()
    } else {
      surfaceHost.canvasHostView.layer.mask = nil
    }

    if featureFocus.isCropEditing {
      toolSurface.hideCanvasView()
      guard let crop = state.proposedCrop else { return }
      cropSurface.draw(viewport: makeDisplayViewport(
        for: cropSurface, layers: layers, contentSize: crop.imageSize,
        contentToZoomingScale: crop.imageToPlatterScale()
      ))
    } else {
      cropSurface.hideCanvasView()
      guard let geometry = toolSurface.outputGeometry else { return }
      toolSurface.draw(viewport: makeDisplayViewport(
        for: toolSurface, layers: layers, contentSize: geometry.outputSize, contentToZoomingScale: 1
      ))
      // Reconciliation remains a gesture-boundary operation. The old loop's
      // stop callback owned this quiet check; the persistent loop observes the
      // same boundary without tying it to rendering's lifetime.
      settleToolScrollInsetIfNeeded()
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

  func multiplied(_ value: CGFloat) -> Self {
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

extension CropDisplayViewport {
  var editingCanvasViewport: _EditingCanvasMTKView.Viewport {
    .init(
      visibleContentRect: visibleContentRect,
      contentToCanvasTransform: contentToCanvasTransform
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

  /// Keep stroke starts inside the displayed image even though the recognizer
  /// now lives on the fixed host. Subsequent points may leave the image bounds.
  public func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldReceive touch: UITouch
  ) -> Bool {
    guard gestureRecognizer === toolSurface.drawingGestureRecognizer else { return true }
    if toolSurface.drawingGestureRecognizer.isTrackingTouch { return true }
    guard let geometry = toolSurface.outputGeometry,
          let point = toolContentPoint(from: touch.location(in: self)) else { return false }
    return CGRect(origin: .zero, size: geometry.outputSize).contains(point)
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

    cropSurface.updateRenderedEditPreview(document: document, crop: crop)
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
    guard let currentLocalEffect = resolvedMaskSeedEffect else {
      return
    }

    document.appendMaskStroke(
      record: record,
      effect: currentLocalEffect
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
