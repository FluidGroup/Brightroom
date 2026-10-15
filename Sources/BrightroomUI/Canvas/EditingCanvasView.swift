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

/// The prepared image an `EditingCanvasView` edits over.
struct EditingCanvasSource {

  /// The oriented, downsampled, GPU-resident editing source (zero origin).
  let editingSourceImage: CIImage

  /// The oriented source size at full resolution: the domain the feature is
  /// authored in.
  let imageSize: CGSize

  init(_ previewSource: PreviewSource) {
    self.editingSourceImage = previewSource.image
    self.imageSize = previewSource.source.pixelSize
  }

  init(editingSourceImage: CIImage, imageSize: CGSize) {
    self.editingSourceImage = editingSourceImage
    self.imageSize = imageSize
  }
}

extension ImageEditorFeature.Effects {

  /// The global effects as the canvas factories take them: nil when no effect
  /// is present, so the canvas can sample its cached source instead of
  /// evaluating an identity graph.
  var canvasEffect: AnyImageEffect? {
    self == Self() ? nil : AnyImageEffect(self)
  }
}

extension ImageEditorFeature {

  /// The effect the canvas draws after the crop (the vignette), or nil.
  ///
  /// It is drawn over the crop frame of each displayed frame instead of
  /// being part of the render images, so changing it never rebuilds them.
  var canvasPostCropEffect: AnyImageEffect? {
    vignette.map { AnyImageEffect($0) }
  }
}

/// A UIKit canvas that edits an `ImageEditorFeature`: value in, changes out.
///
/// Based on the editing vision in `docs/vision-of-editing.md`, the feature
/// evaluates tool edits before the final crop:
///
/// ```text
/// Source -> Effects -> Blur Mask -> Final Crop -> Vignette -> Output
/// ```
///
/// The host passes the feature with `setFeature(_:)` and receives EditingCanvasView's
/// own changes (crop commits, brush strokes) through the feature change
/// handler. `ImageEditorCanvas.Target` picks what canvas gestures edit; the
/// viewing point is always the feature's output. Crop editing adjusts the
/// final crop while showing the effects and the blur mask over the whole
/// source, and the vignette inside the crop guide, centred on it as it moves. Mask editing inspects the output through the crop while authoring
/// strokes that belong to the pre-crop domain, so Tool navigation never
/// mutates the crop, and strokes cross domains when they are displayed or
/// committed.
///
/// Crop adjustment is available in two ways:
/// - Scrolling the image.
/// - Panning the guide.
///
/// - TODO:
///   - Implicit animations occurs in first time load with remote image.
final class EditingCanvasView: UIView {

  /// A change EditingCanvasView made to the feature: a crop commit or a brush stroke.
  ///
  /// The feature's owner applies it to its latest feature, so owner-side
  /// changes EditingCanvasView has not received yet are kept.
  typealias FeatureChange = (inout ImageEditorFeature) -> Void

  private struct State {

    var proposedCrop: CropGuideState?

    var frame: CGRect = .zero

    /// Mirrors `InteractiveCropGuideView.interaction`, which owns the set.
    var interaction: CropInteraction = []

    /// The locked aspect ratio in the final output orientation.
    var lockedAspectRatio: AspectRatio?

    var cropGuide: ImageEditorCanvas.CropGuide {
      .init(
        pendingCrop: proposedCrop?.makeCropFeature(),
        canvasBounds: CGRect(origin: .zero, size: frame.size),
        interaction: interaction,
        lockedAspectRatio: lockedAspectRatio
      )
    }
  }

  private enum ScrollViewAdjustmentKind {
    case drag
    case zoom
  }

  private struct ScrollViewAdjustmentSession {
    let kind: ScrollViewAdjustmentKind
    let baselineCrop: CropGuideState
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

  var areAnimationsEnabled: Bool = true {
    didSet {
      guideView.animatesRestoringFrame = areAnimationsEnabled
    }
  }

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

  /// The prepared image the feature is authored over.
  private let source: EditingCanvasSource

  /// The feature as EditingCanvasView last received or changed it.
  ///
  /// It is also the echo reference: a feature passed back with the same crop
  /// does not reload the crop state.
  private var feature: ImageEditorFeature

  private var featureChangeHandler: @MainActor (@escaping FeatureChange) -> Void = { _ in }

  /// The committed strokes of `feature.localBlur` as canvas records, reused
  /// while the mask (and, for the tool surface, the crop output) is unchanged.
  private var committedStrokeRecords = CommittedStrokeRecords()

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
  /// Internal (not private) so tests can drive its scroll view's delegate.
  let cropSurface = CropSurface()
  /// Internal (not private) so tests can read whether its drawing gesture
  /// paints.
  let toolSurface = ToolSurface()

  /// What the host asked canvas gestures to edit; nil views the output only.
  private var editingTarget: ImageEditorCanvas.Target? = .crop

  /// What canvas gestures edit now: `editingTarget`, except that a local
  /// blur the canvas cannot paint (`ImageEditorFeature.isLocalBlurPaintable`)
  /// is viewed only, as with a nil target.
  private var activeEditingTarget: ImageEditorCanvas.Target? {
    if editingTarget == .localBlur, feature.isLocalBlurPaintable == false {
      return nil
    }
    return editingTarget
  }

  /// Whether the crop guide and the crop scroll surface own interaction.
  private var isCropEditing: Bool {
    activeEditingTarget == .crop
  }

  /// Whether brush gestures paint the blur mask.
  private var isMaskEditing: Bool {
    activeEditingTarget == .localBlur
  }
  private var brush: ImageEditorCanvas.Brush = .init(diameter: .viewportPoints(30))
  /// The image-space brush most recently pushed to the canvas surfaces, used
  /// to skip redundant reconfiguration when neither the brush nor the
  /// geometry it resolves against has changed.
  private var appliedCanvasBrush: EditingCanvasBrush?
  /// True while an external control streams straighten angle changes before
  /// committing the resulting crop extent.
  ///
  /// Streaming straighten updates mutate the crop scroll transform without
  /// animation. During that phase, viewport conversion should read model layers
  /// so Metal rendering does not chase stale presentation-layer geometry.
  private var isStreamingStraightenAngle = false

  private var hasSetupScrollViewCompleted = false

  /**
   a guide view that displayed on guide container view.
   */
  /// Internal (not private) so tests can report a guide resize, which
  /// begins and ends through its `insertInteraction(_:)` and
  /// `removeInteraction(_:)`.
  private(set) lazy var guideView = InteractiveCropGuideView(
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
  private let debounce = Debouncer(interval: 0.8)

  private let scrollViewSettleDebounce = Debouncer(interval: 0.2)

  private let contentInset: UIEdgeInsets

  private var scrollViewAdjustmentSession: ScrollViewAdjustmentSession?

  /// The crop scroll view's pinch, carried on this view so that a finger on
  /// a guide handle counts toward it (see `adoptCropPinchGestureRecognizer`).
  private(set) var adoptedCropPinchGestureRecognizer: UIGestureRecognizer?

  /// The crop scroll view's gestures in progress, from their begin callback
  /// to their end (a flicked drag ends when its deceleration ends). The guide
  /// reports `.movingImage` while any is in progress.
  ///
  /// Tracked apart from `scrollViewAdjustmentSession`, which keeps one
  /// session for recording the crop: a pinch replaces a drag's session and a
  /// drag that starts during a pinch opens none, but the image is still
  /// moving until both gestures end.
  private var imageMovingGestures: Set<ScrollViewAdjustmentKind> = [] {
    didSet {
      if imageMovingGestures.isEmpty {
        guideView.removeInteraction(.movingImage)
      } else {
        guideView.insertInteraction(.movingImage)
      }
    }
  }

  private var scrollViewAdjustmentKind: ScrollViewAdjustmentKind? {
    scrollViewAdjustmentSession?.kind
  }

  private var cropGuideHandler: @MainActor (ImageEditorCanvas.CropGuide) -> Void = { _ in }

  /// True while `layoutSubviews` reports the crop guide for a new canvas
  /// size. Layout can run inside a SwiftUI view update, so the SwiftUI
  /// coordinator delivers such a guide on a later main-actor turn.
  private(set) var isReportingCropGuideFromLayout = false

  private var lastLaidOutCrop: CropGuideState?

  // MARK: - Initializers

  /// Creates a canvas over `source` editing `feature`.
  ///
  /// This only stores the values. Call `loadFeature()` once a crop guide
  /// handler is bound, so the first crop guide reaches it.
  init(
    source: EditingCanvasSource,
    feature: ImageEditorFeature,
    contentInset: UIEdgeInsets = .init(top: 20, left: 20, bottom: 20, right: 20)
  ) {
    self.source = source
    self.feature = feature
    self.contentInset = contentInset

    super.init(frame: .zero)

    identifiers: do {
      accessibilityIdentifier = "EditingCanvasView"
      surfaceHost.platterView.accessibilityIdentifier = "EditingCanvasView.surfaceHost.platterView"
      surfaceHost.backdropView.accessibilityIdentifier = "scrollBackdropView"
      cropSurface.scrollView.accessibilityIdentifier = "EditingCanvasView.cropSurface.scrollView"
      cropSurface.imagePlatterView.accessibilityIdentifier = "EditingCanvasView.cropSurface.imagePlatterView"
      toolSurface.scrollView.accessibilityIdentifier = "EditingCanvasView.toolSurface.scrollView"
      toolSurface.contentView.accessibilityIdentifier = "EditingCanvasView.toolSurface.contentView"
    }

    clipsToBounds = false

    addSubview(surfaceHost.platterView)
    surfaceHost.platterView.addSubview(surfaceHost.backdropView)
    surfaceHost.platterView.addSubview(cropSurface.scrollView)
    surfaceHost.platterView.addSubview(toolSurface.scrollView)

    surfaceHost.canvasHostView.isUserInteractionEnabled = false
    surfaceHost.canvasHostView.clipsToBounds = true
    surfaceHost.canvasHostView.accessibilityIdentifier = "EditingCanvasView.fixedCanvasHost"
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
    // The shared CropScrollView defaults enable alwaysBounce for the crop
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
      // Zooming and scrolling schedule no layout. updateCropLayout() moves
      // the scroll view to proposedCrop, which a gesture changes only when
      // its settle records it; a layout scheduled from these events could
      // run first (a zoom bounce or a rest outside the scroll range keeps
      // the settle waiting) and move the image back to the crop from before
      // the gesture. The settle lays out once, right after it records
      // (didSettleScrollViewAdjustment).
      cropSurface.onDidZoom = { [weak self] in
        guard let self else { return }
        self.debugLogScrollViewAdjustment("did-zoom")
      }
      cropSurface.onDidScroll = { [weak self] in
        guard let self else { return }
        self.debugLogScrollViewAdjustment("did-scroll")
      }
      cropSurface.onWillBeginDragging = { [weak self] in
        guard let self else { return }
        self.debugLogScrollViewAdjustment("drag-begin")
        self.beginScrollViewAdjustment(.drag)
        self.imageMovingGestures.insert(.drag)
      }
      cropSurface.onWillBeginZooming = { [weak self] in
        guard let self else { return }
        self.debugLogScrollViewAdjustment("zoom-begin")
        self.beginScrollViewAdjustment(.zoom)
        self.imageMovingGestures.insert(.zoom)
        // A pinch whose first finger started dragging a guide handle zooms;
        // the resize it began is dropped. Dropped after the zoom is
        // reported, so the interaction goes from resizing to moving the
        // image without passing through idle. A resize leaves the crop as
        // it was until it ends, so the zoom's baseline is the same.
        self.guideView.cancelResizing()
      }
      cropSurface.onDidEndDragging = { [weak self] decelerate in
        guard let self else { return }
        self.debugLogScrollViewAdjustment("drag-end decelerate:\(decelerate)")

        if !decelerate {
          self.endScrollViewAdjustment(.drag)
          self.imageMovingGestures.remove(.drag)
        }
      }
      cropSurface.onDidEndZooming = { [weak self] scale in
        guard let self else { return }
        self.debugLogScrollViewAdjustment("zoom-end scale:\(scale)")
        self.endScrollViewAdjustment(.zoom)
        self.imageMovingGestures.remove(.zoom)
      }
      cropSurface.onDidEndDecelerating = { [weak self] in
        guard let self else { return }
        self.debugLogScrollViewAdjustment("deceleration-end")
        self.endScrollViewAdjustment(.drag)
        self.imageMovingGestures.remove(.drag)
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

    guideView.didCancelChange = { [weak self] in
      guard let self = self else { return }
      self.didCancelGuideViewChange()
    }

    guideView.didUpdateInteraction = { [weak self] interaction in
      guard let self else { return }
      self.state.interaction = interaction
      self.emitCropGuide()
    }

    // apply defaultAppearance
    do {
      setCropInsideOverlay(EditingCanvasView.CropInsideOverlayRuleOfThirdsView())
      setCropOutsideOverlay(EditingCanvasView.CropOutsideOverlayBlurredView())
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

  /// Sets the handler that receives the crop guide each time the canvas
  /// reports it. The canvas may report an unchanged guide; the SwiftUI
  /// coordinator drops repeats.
  func setCropGuideHandler(_ handler: @escaping @MainActor (ImageEditorCanvas.CropGuide) -> Void) {
    self.cropGuideHandler = handler
  }

  /// The crop guide's working state, which the reported guide shows as
  /// `pendingCrop`; nil until the feature is loaded.
  var proposedCrop: CropGuideState? {
    state.proposedCrop
  }

  /// Sets the handler that receives the changes EditingCanvasView makes: crop commits
  /// and brush strokes. The owner applies each one to its latest feature.
  func setFeatureChangeHandler(
    _ handler: @escaping @MainActor (_ change: @escaping FeatureChange) -> Void
  ) {
    self.featureChangeHandler = handler
  }

  /// Loads the crop state from the feature and displays it.
  ///
  /// Call it once, after the crop guide handler is bound: loading reports the
  /// first crop guide.
  func loadFeature() {
    load(crop: CropGuideState(cropFeature: feature.crop, imageSize: source.imageSize))
    updateDisplay()
  }

  /// Displays `feature`.
  ///
  /// When its crop differs from the crop EditingCanvasView holds (for example after an
  /// undo), the crop state reloads under the active aspect-ratio lock, which
  /// first turns with the reloaded crop's output orientation unless that
  /// output already has the lock as it is. A reloaded crop
  /// that already has the locked ratio keeps its position and size; one that
  /// does not is fitted inside its own rectangle, not at the image center. A
  /// feature EditingCanvasView changed itself comes back equal and only refreshes the
  /// display.
  func setFeature(_ feature: ImageEditorFeature) {
    guard feature != self.feature else {
      updateDisplay()
      return
    }

    let cropChanged = feature.crop.isPixelEquivalent(
      to: self.feature.crop,
      imageSize: source.imageSize
    ) == false
    let localBlurChanged = feature.localBlur != self.feature.localBlur
    let wasMaskEditing = isMaskEditing
    self.feature = feature

    if cropChanged, let current = state.proposedCrop {
      var crop = CropGuideState(cropFeature: feature.crop, imageSize: source.imageSize)
      if let lock = state.lockedAspectRatio {
        // The lock describes the output, so it turns with the reloaded crop's
        // output orientation, as it does in `setQuarterTurn(_:)`, unless the
        // reloaded output already has the lock as it is.
        let ratio = crop.aspectRatioLock(lock, replacingSideways: current.rotation.isSideways)
        if ratio != lock {
          state.lockedAspectRatio = ratio
          guideView.setLockedAspectRatio(ratio)
        }
        crop.adoptAspectRatio(ratio)
      }
      load(crop: crop)
    }

    // Effects-only changes (slider ticks, presets) leave the strokes alone.
    if cropChanged || localBlurChanged {
      syncCommittedStrokesFromFeature()
    }
    // A local blur replaced with one the canvas cannot paint (or back) turns
    // painting off (or on); turning it off cancels a stroke in progress.
    if isMaskEditing != wasMaskEditing {
      applySurfaceMode()
    }
    updateDisplay()
  }

  /**
   Applies the proposed crop to the feature.

   Interaction callbacks record view geometry into the proposed crop. Committing
   uses that value directly so layout rounding cannot change an untouched crop.
   */
  func applyPendingCrop() {
    // A straighten edit the host ended in the same action reaches the
    // canvas only on the next view update; record its crop first so the
    // write is the recorded crop, not the streamed one.
    finishStreamedStraightening()
    // Likewise a zoom or a pan whose settle has not recorded it yet.
    finishPendingScrollAdjustment()

    guard let crop = state.proposedCrop else {
      EditorLog.error(.editingCanvas, "EditingCanvasView has not loaded the feature state.")
      return
    }
    applyCropToFeatureIfRenderingChanged(crop)
  }

  func resetCrop() {
    debounce.cancel()
    scrollViewSettleDebounce.cancel()
    scrollViewAdjustmentSession = nil
    isStreamingStraightenAngle = false
    state.lockedAspectRatio = nil
    guideView.setLockedAspectRatio(nil)

    if let crop = state.proposedCrop {
      setProposedCrop(crop.makeInitial(), previousCrop: crop, forcesLayout: true)
    }

    // The reset snaps the image and drops the scroll session, so an image
    // move in progress ends here; its later end callbacks change nothing. A
    // guide resize in progress keeps going and ends with its gesture.
    imageMovingGestures.removeAll()

    emitCropGuide()
  }

  func setQuarterTurn(_ rotation: QuarterTurn) {
    guard var crop = state.proposedCrop, crop.rotation != rotation else {
      return
    }

    let swapsDimensions = crop.updateRotation(to: rotation)
    if swapsDimensions, let lockedAspectRatio = state.lockedAspectRatio?.swapped() {
      state.lockedAspectRatio = lockedAspectRatio
      guideView.setLockedAspectRatio(lockedAspectRatio)
    }
    setProposedCrop(crop, forcesLayout: true)
  }

  /// Turns the output a further quarter counterclockwise on screen.
  func rotateCounterclockwise() {
    guard let crop = state.proposedCrop else {
      return
    }
    setQuarterTurn(crop.rotation.turnedCounterclockwise())
  }

  func setStraightenAngle(
    _ angle: Angle,
    recordsCropExtent: Bool = true
  ) {
    guard var crop = state.proposedCrop, crop.adjustmentAngle != angle else {
      return
    }

    isStreamingStraightenAngle = recordsCropExtent == false
    crop.adjustmentAngle = angle
    setProposedCrop(crop, animatesLayout: false)

    if recordsCropExtent {
      record()
      isStreamingStraightenAngle = false
    }
  }

  func endStraightening(at angle: Angle) {
    setStraightenAngle(angle, recordsCropExtent: false)
    record()
    isStreamingStraightenAngle = false

  }

  /// Ends a streamed straighten edit at the angle on screen, recording the
  /// crop; does nothing when no edit is streaming.
  func finishStreamedStraightening() {
    guard isStreamingStraightenAngle else {
      return
    }
    record()
    isStreamingStraightenAngle = false
  }

  /// Records a zoom or a pan whose settle has not run yet, as the scroll
  /// view shows it now, and lays out as the settle does; does nothing when
  /// no scroll adjustment is waiting.
  ///
  /// Applying the crop (leaving crop editing, the host's Done) cannot wait
  /// for the settle: once the crop is no longer the editing target the
  /// settle records nothing, and the crop applied would be the one from
  /// before the gesture. A deceleration in progress stops where it is.
  private func finishPendingScrollAdjustment() {
    guard scrollViewAdjustmentSession != nil else {
      return
    }
    scrollViewSettleDebounce.cancel()
    let scrollView = cropSurface.scrollView
    if scrollView.isDecelerating {
      scrollView.setContentOffset(scrollView.contentOffset, animated: false)
      imageMovingGestures.remove(.drag)
    }
    debugLogScrollViewAdjustment("settle-finish")
    didSettleScrollViewAdjustment()
  }

  func setCrop(_ crop: CropGuideState) {
    var crop = crop
    if let ratio = state.lockedAspectRatio, crop._usedAspectRatio != ratio {
      crop.adoptAspectRatio(ratio)
    }
    setProposedCrop(crop)
  }

  func setLockedAspectRatio(_ ratio: AspectRatio?) {
    guard state.lockedAspectRatio != ratio else {
      return
    }

    state.lockedAspectRatio = ratio
    var crop = state.proposedCrop
    if let ratio = ratio {
      // A selection that already has the ratio (a reopened `.fixed` editor,
      // a face crop of that ratio) is kept; otherwise the picker's centered
      // maximum crop of the new ratio.
      if crop?.hasAspectRatio(ratio) == true {
        crop?.adoptAspectRatio(ratio)
      } else {
        crop?.updateCropExtentIfNeeded(toFitAspectRatio: ratio)
      }
    } else {
      crop?.purgeAspectRatio()
    }
    if let crop {
      setProposedCrop(crop, forcesLayout: true)
    } else {
      updateCropLayout()
    }

    guideView.setLockedAspectRatio(ratio)
    emitCropGuide()
  }

  /**
   Displays a view as an overlay.
   e.g. grid view

   - Parameters:
   - view: In case of no needs to display overlay, pass nil.
   */
  func setCropInsideOverlay(_ view: CropInsideOverlayBase?) {
    guideView.setCropInsideOverlay(view)
  }

  func swapCropRectangleDirection() {
    guard var crop = state.proposedCrop else {
      return
    }

    crop.updateCropExtentIfNeeded(
      toFitAspectRatio: AspectRatio(crop.outputCropExtent.size).swapped()
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

extension EditingCanvasView {
  private func load(crop: CropGuideState) {
    prepareForCropIfNeeded(crop)
    setProposedCrop(crop, forcesLayout: true)
  }

  private func prepareForCropIfNeeded(_ crop: CropGuideState) {
    if state.proposedCrop?.imageSize != crop.imageSize {
      hasSetupScrollViewCompleted = false
      lastLaidOutCrop = nil
      cropSurface.removeCanvasView()
      toolSurface.removeCanvasView()
    }
  }

  private func updateDisplay() {
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
        smoothing: brush.smoothing,
        onStrokeCommit: { [weak self] record, completion in
          self?.commitCanvasStroke(record: record, completion: completion)
        }
      ) != nil
    }

    switch activeEditingTarget {
    case .crop:
      toolSurface.hideCanvasView()
      guard
        cropSurface.ensureCanvasView(
          in: surfaceHost.canvasHostView,
          canvasSize: crop.imageSize,
          brush: canvasBrush,
          smoothing: brush.smoothing,
          onStrokeCommit: { [weak self] record, completion in
            self?.commitCanvasStroke(record: record, completion: completion)
          }
        ) != nil
      else {
        return
      }

      cropSurface.updateRenderedEditPreview(
        source: source,
        feature: feature,
        crop: crop,
        committedStrokes: committedStrokeRecords.sourceRecords(
          localBlur: feature.localBlur,
          domainHeight: source.imageSize.height
        )
      )

    case .localBlur:
      guard
        let geometry = EditingCanvasCropOutputGeometry(crop: crop),
        ensureToolCanvas(geometry: geometry)
      else {
        return
      }

      // Before the first stroke the live stroke previews the default blur.
      // It equals the content the first stroke creates, so the canvas key and
      // its bakes survive that commit.
      toolSurface.updateCanvas(
        source: source,
        effects: feature.effects,
        geometry: geometry,
        mode: .localAdjustment(
          effect: AnyImageEffect(feature.localBlur?.content ?? ImageEditorFeature.defaultLocalBlurContent)
        ),
        committedStrokes: committedStrokeRecords.outputRecords(
          localBlur: feature.localBlur,
          geometry: geometry,
          domainHeight: source.imageSize.height
        )
      )

    case nil:
      guard
        let geometry = EditingCanvasCropOutputGeometry(crop: crop),
        ensureToolCanvas(geometry: geometry)
      else {
        return
      }

      toolSurface.updateCanvas(
        source: source,
        effects: feature.effects,
        geometry: geometry,
        mode: CanvasRenderPlan(localBlur: feature.localBlur).canvasMode,
        committedStrokes: committedStrokeRecords.outputRecords(
          localBlur: feature.localBlur,
          geometry: geometry,
          domainHeight: source.imageSize.height
        )
      )
    }
  }

  /// The inputs that decide the crop surface's render images. Equal keys keep
  /// the canvas's render images and bakes.
  struct CanvasInputKey: Equatable {
    var imageSize: CGSize
    var sourceImage: ObjectIdentifier
    var sourceExtent: CGRect
    var effects: ImageEditorFeature.Effects
    /// The whole blur mask, strokes included: the crop surface rebuilds on a
    /// stroke commit.
    var localBlur: LocalAdjustmentFeature<GaussianBlurFeature>?

    init(source: EditingCanvasSource, feature: ImageEditorFeature, crop: CropGuideState) {
      let previewSourceImage = ImageGeometry.removingExtentOffset(source.editingSourceImage)
      self.imageSize = crop.imageSize
      // Extent alone cannot detect a same-size source replacement (the
      // editing source is always capped to the same max pixel size).
      self.sourceImage = ObjectIdentifier(source.editingSourceImage)
      self.sourceExtent = previewSourceImage.extent
      self.effects = feature.effects
      self.localBlur = feature.localBlur
    }
  }

  /// How the canvas composites the feature's blur mask.
  ///
  /// Internal (not private) so tests can verify the stroke-domain mapping.
  enum CanvasRenderPlan: Equatable {

    /// No blur is composited: the canvas shows the global effects only.
    case viewportBase

    /// The blur mask is composited over the global effects.
    case localBlur(LocalAdjustmentFeature<GaussianBlurFeature>)

    /// `.localBlur` when the mask is present, rooted at a brush, and has at
    /// least one stroke. An empty brush changes nothing at export, so the
    /// canvas does not composite it either.
    init(localBlur: LocalAdjustmentFeature<GaussianBlurFeature>?) {
      guard
        let localBlur,
        case let .brush(brush) = localBlur.mask,
        brush.strokes.isEmpty == false
      else {
        self = .viewportBase
        return
      }
      self = .localBlur(localBlur)
    }

    var canvasMode: EditingCanvasMode {
      switch self {
      case .viewportBase:
        return .viewportBase
      case let .localBlur(layer):
        return .localAdjustment(effect: AnyImageEffect(layer.content))
      }
    }

    /// The committed strokes as canvas display records (y-down).
    ///
    /// The feature stores strokes in the working space (y-up) of the
    /// pre-crop source domain.
    ///
    /// - Parameters:
    ///   - geometry: The crop-output geometry when the destination canvas
    ///     displays the crop output, or nil when the canvas is sized to the
    ///     source image.
    ///   - domainHeight: The oriented source height.
    func committedStrokes(
      in geometry: EditingCanvasCropOutputGeometry?,
      domainHeight: CGFloat
    ) -> [EditingCanvasStrokeRecord] {
      switch self {
      case .viewportBase:
        return []
      case let .localBlur(layer):
        let sourceRecords = layer.mask.brushStrokes.map {
          EditingCanvasStrokeRecord(workingSpaceStroke: $0, domainHeight: domainHeight)
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

  /// The layer coordinates sampled together for one displayed frame.
  /// Content placement, guide clipping, and the crop guide that frames the
  /// post-crop pass must use the same animation state.
  private struct DisplayLayers {
    let content: CALayer
    let canvas: CALayer
    let clip: CALayer
    let guide: CALayer
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
    let guide = guideView.layer
    if hasViewportAnimation(for: surface) || guide.animationKeys()?.isEmpty == false,
       let contentPresentation = content.presentation(),
       let canvasPresentation = canvas.presentation(),
       let clipPresentation = clip.presentation(),
       let guidePresentation = guide.presentation() {
      return DisplayLayers(
        content: contentPresentation,
        canvas: canvasPresentation,
        clip: clipPresentation,
        guide: guidePresentation
      )
    }
    return DisplayLayers(content: content, canvas: canvas, clip: clip, guide: guide)
  }

  /// Converts three content landmarks without discarding rotation through an
  /// enclosing rectangle. The fixed canvas and its drawable retain their size.
  private func makeDisplayViewport(
    for surface: CanvasSurface,
    layers: DisplayLayers,
    contentSize: CGSize,
    contentToZoomingScale: CGFloat
  ) -> CanvasViewport? {
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
    let transform = CanvasViewport.contentTransform(
      contentSize: contentSize, origin: origin,
      horizontalCorner: horizontal, verticalCorner: vertical
    )
    return CanvasViewport(
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
    _ crop: CropGuideState,
    previousCrop: CropGuideState? = nil,
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

  private func emitCropGuide() {
    cropGuideHandler(state.cropGuide)
  }

  @discardableResult
  private func updateProposedCrop(_ crop: CropGuideState) -> Bool {
    guard state.proposedCrop != crop else {
      return false
    }

    state.proposedCrop = crop

    emitCropGuide()

    return true
  }

  #if DEBUG
  private func debugLogRecordedCropExtent(
    source: ScrollViewAdjustmentKind?,
    normalizedRect: CGRect,
    resolvedRect: CGRect
  ) {
    guard state.lockedAspectRatio != nil || source != nil else {
      return
    }

    EditorLog.debug(.editingCanvas, """
      [CropRecord]
      source: \(String(describing: source))
      lockedAspectRatio: \(String(describing: state.lockedAspectRatio))
      normalizedAspect: \(Self.debugAspectRatio(normalizedRect.size))
      resolvedAspect: \(Self.debugAspectRatio(resolvedRect.size))
      """)
  }

  private func debugLogScrollViewAdjustment(_ event: String) {
    guard state.lockedAspectRatio != nil || scrollViewAdjustmentSession != nil else {
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

    EditorLog.debug(.editingCanvas, """
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

  private func applyCropToFeatureIfRenderingChanged(_ crop: CropGuideState) {
    // Pixel-aligned, to exactly the locked ratio when the guide recorded it
    // under a lock (`CropGuideState.makeCropFeature()`).
    let cropFeature = crop.makeCropFeature()
    guard
      feature.crop.isPixelEquivalent(
        to: cropFeature,
        imageSize: crop.imageSize
      ) == false
    else {
      return
    }

    commitFeatureChange { feature in
      feature.crop = cropFeature
    }
  }

  /// Applies a change to EditingCanvasView's feature and reports it to the owner.
  /// A change that leaves the feature equal is not reported.
  private func commitFeatureChange(_ change: @escaping FeatureChange) {
    var next = feature
    change(&next)
    guard next != feature else {
      return
    }

    let localBlurChanged = next.localBlur != feature.localBlur
    feature = next
    featureChangeHandler(change)

    if localBlurChanged {
      syncCommittedStrokesFromFeature()
    }
    updateDisplay()
  }

  private func updateCropLayout(
    previousCrop: CropGuideState? = nil,
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

      // The guide reports the canvas bounds.
      if previousFrame.size != frame.size {
        isReportingCropGuideFromLayout = true
        emitCropGuide()
        isReportingCropGuideFromLayout = false
      }
    }

    #if DEBUG
    surfaceHost.platterView.layer.addSublayer(_debug_shapeLayer)
    #endif


  }

  private func updateScrollContainerView(
    by crop: CropGuideState,
    animated: Bool,
    animatesRotation: Bool
  ) {
    func perform() {

      frame: do {

        let contentRect: CGRect = {

          let bounds = self.bounds.inset(by: contentInset)

          let size = AspectRatio(crop.outputCropExtent.size)
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

          let size = AspectRatio(crop.outputCropExtent.size)
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

          // A crop under the editor's minimum size (one a host set) raises
          // the maximum, so the guide shows exactly that crop.
          let (min, max) = crop.zoomScaleRange(
            visibleSize: guideView.bounds
              .applying(CGAffineTransform(rotationAngle: crop.aggregatedRotation.radians))
              .size,
            guideSize: guideView.bounds.size
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

          adoptCropPinchGestureRecognizer()

          updateToolScrollGeometry(crop: crop)

        }


      }

    }

    if animated {
      layoutIfNeeded()

      if animatesRotation {
        let animator = UIViewPropertyAnimator(duration: 0.6, dampingRatio: 1) {
          perform()
        }
        animator.isUserInteractionEnabled = false
        animator.startAnimation()

        let guideAnimator = UIViewPropertyAnimator(duration: 0.12, dampingRatio: 1) {
          self.guideView.alpha = 0
        }
        guideAnimator.isUserInteractionEnabled = false
        guideAnimator.addCompletion { _ in
          UIViewPropertyAnimator(duration: 0.5, dampingRatio: 1) {
            self.setCropGuideVisibility(isVisible: self.isCropEditing)
          }
          .startAnimation(afterDelay: 0.8)
        }
        guideAnimator.startAnimation()

      } else {
        UIViewPropertyAnimator(duration: 0.6, dampingRatio: 1) { [self] in
          perform()
          layoutIfNeeded()
        }
        .startAnimation()
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

  private func makeScrollViewInset(aggregatedRotation: CGFloat) -> UIEdgeInsets {

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
            .concatenating(.init(rotationAngle: -aggregatedRotation))
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

  private func updateScrollViewInset(crop: CropGuideState) {
    cropSurface.scrollView.contentInset = makeScrollViewInset(
      aggregatedRotation: crop.aggregatedRotation.radians
    )
  }

  private func updateToolScrollGeometry(
    crop: CropGuideState,
    syncsViewportFromCropSurface: Bool = false
  ) {
    guard let geometry = EditingCanvasCropOutputGeometry(crop: crop) else {
      return
    }

    let contentSize = geometry.outputSize
    let isContentSizeChanged = toolSurface.contentView.bounds.size != contentSize
    let shouldResetToolSurface = syncsViewportFromCropSurface
      || isContentSizeChanged
      || toolSurface.lastAppliedCrop?.isPixelEquivalent(to: crop) != true

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
    toolSurface.lastAppliedCrop = crop
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
    scheduleCropLayoutAfterGuideChange(requiresCropEditing: false)
  }

  /// The guide went back to its frame from before a resize that a pinch
  /// took over. `willChangeGuideView` dropped any pending layout, so
  /// schedule it again once the fingers lift.
  private func didCancelGuideViewChange() {
    scheduleCropLayoutAfterGuideChange(requiresCropEditing: true)
  }

  /// Runs `updateCropLayout()` after `debounce`'s delay, for a change the
  /// guide made.
  ///
  /// The layout moves the crop scroll view to `proposedCrop`. While the
  /// scroll view moves, or has moved and its settle has not recorded the
  /// crop yet, that would move the image back to the crop from before the
  /// gesture. A scroll adjustment waiting to be recorded lays out when it
  /// settles (`didSettleScrollViewAdjustment`); any other motion defers the
  /// layout by another delay.
  private func scheduleCropLayoutAfterGuideChange(requiresCropEditing: Bool) {
    debounce.on { [weak self] in
      guard let self else { return }
      if requiresCropEditing {
        guard self.isCropEditing else { return }
      }
      guard self.scrollViewAdjustmentSession == nil else { return }

      let scrollView = self.cropSurface.scrollView
      guard
        scrollView.isTracking == false,
        scrollView.isDecelerating == false,
        scrollView.isZoomBouncing == false,
        self.cropSurface.isInteractiveZoomGestureActive == false
      else {
        self.scheduleCropLayoutAfterGuideChange(requiresCropEditing: requiresCropEditing)
        return
      }

      self.updateCropLayout()
    }
  }

  /// Carries the crop scroll view's pinch on this view instead of on the
  /// scroll view.
  ///
  /// A touch reaches only the recognizers of the view it lands on and that
  /// view's ancestors. The guide's handles sit beside the scroll view, so a
  /// pinch finger that lands within a handle's 16 pt reach used to be
  /// invisible to the pinch: the handle resized the guide while the other
  /// finger panned the image. On this view, the common ancestor, the pinch
  /// tracks both fingers, and the handles yield to it. The scroll view still
  /// handles the pinch (its target and delegate are unchanged), so zooming,
  /// bouncing, and the zoom callbacks behave as before.
  ///
  /// UIScrollView drops its pinch while the minimum and maximum zoom scales
  /// are equal and creates a new one when they differ again, so this runs
  /// after every zoom-scale write: it removes a dropped pinch and adopts the
  /// new one, enabled only while the crop is the editing target, as
  /// `CropSurface.applyMode(isActive:)` does.
  private func adoptCropPinchGestureRecognizer() {
    let pinch = cropSurface.scrollView.pinchGestureRecognizer
    guard pinch !== adoptedCropPinchGestureRecognizer else {
      return
    }

    if let dropped = adoptedCropPinchGestureRecognizer {
      removeGestureRecognizer(dropped)
    }
    adoptedCropPinchGestureRecognizer = pinch
    guideView.imageZoomGestureRecognizer = pinch

    if let pinch {
      pinch.isEnabled = isCropEditing
      addGestureRecognizer(pinch)
    }
  }

  /// How `record()` brings the selection measured on screen inside the
  /// image.
  private enum CropRecordingBounds {
    /// Clip to the image, and fit the locked ratio inside what remains: the
    /// guide itself changed (a resize or a straighten).
    case clipping
    /// Keep the guide's size and ratio, and move it inside the image: the
    /// image moved under the guide (a zoom or a pan).
    case translating
  }

  @discardableResult
  private func record(bounds: CropRecordingBounds = .clipping) -> CropGuideState? {

    // Crop recording only applies while the crop is the editing target. In
    // the other targets the scroll view is a free pan/zoom viewport and must
    // not mutate the crop extent.
    guard isCropEditing else {
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

    // The untransformed guide has the output's orientation. Convert it once
    // into the stored selection before the quarter turn.
    let convertedCropExtent = crop.makeCropExtent(
      rect: guideRectInImageView
    )
    let normalizedCropExtent = normalizedCropExtentForScrollViewRecording(
      convertedCropExtent,
      currentCrop: crop
    )
    let resolvedRect: CGRect
    switch bounds {
    case .clipping:
      resolvedRect = cropExtentRespectingLockedAspectRatio(
        normalizedCropExtent,
        currentCrop: crop
      )
    case .translating:
      resolvedRect = cropExtentTranslatedIntoImage(
        normalizedCropExtent,
        currentCrop: crop
      )
    }
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

  private func cropExtentRespectingLockedAspectRatio(
    _ cropExtent: CGRect,
    currentCrop: CropGuideState
  ) -> CGRect {
    guard let lockedAspectRatio = state.lockedAspectRatio else {
      return cropExtent
    }

    let boundedCropExtent = CropGeometry.fittingRect(
      rect: cropExtent,
      in: currentCrop.imageSize,
      straightenRadians: currentCrop.adjustmentAngle.radians,
      respectingAspectRatio: currentCrop.aspectRatioBeforeOutputRotation(lockedAspectRatio)
    )
    guard boundedCropExtent.isNull == false, boundedCropExtent.isEmpty == false else {
      return cropExtent
    }
    return boundedCropExtent
  }

  /// The guide after a zoom or a pan, moved inside the image.
  ///
  /// The image moved under the guide, so the guide's size on screen is the
  /// crop's size. UIKit rounds the scroll view's offset to device pixels, so
  /// a guide resting against the image edge can sit a fraction of a point
  /// past it, and a rest the scroll view does not bounce back can sit
  /// further. Clipping that and fitting the locked ratio again about the
  /// centre would shrink the crop on both axes and move the opposite edges,
  /// and the layout after the settle would zoom to that smaller crop. Moving
  /// it keeps the size and the ratio, and puts the edge on the image edge.
  /// Without a lock, the crop is moved the same way, so it never extends past
  /// the image.
  private func cropExtentTranslatedIntoImage(
    _ cropExtent: CGRect,
    currentCrop: CropGuideState
  ) -> CGRect {
    var rect = cropExtent
    if let lockedAspectRatio = state.lockedAspectRatio {
      // The guide is laid out with the locked ratio, so this changes nothing
      // beyond rounding, except for a loaded crop kept within rounding of the
      // ratio (`CropGuideState.hasAspectRatio(_:)`), which it makes exact.
      rect = currentCrop.aspectRatioBeforeOutputRotation(lockedAspectRatio).rectThatFits(in: rect)
    }

    let translated = CropGeometry.translatedIntoBounds(
      rect: rect,
      in: currentCrop.imageSize,
      straightenRadians: currentCrop.adjustmentAngle.radians
    )
    guard translated.isNull == false, translated.isEmpty == false else {
      return cropExtent
    }
    return translated
  }

  private func normalizedCropExtentForScrollViewRecording(
    _ cropExtent: CGRect,
    currentCrop: CropGuideState
  ) -> CGRect {
    guard
      let adjustmentSession = scrollViewAdjustmentSession,
      adjustmentSession.kind == .drag,
      adjustmentSession.baselineCrop.adjustmentAngle == .zero,
      currentCrop.adjustmentAngle == .zero
    else {
      return cropExtent
    }

    // Without straighten, the selection before the quarter turn is also its
    // source footprint. Only then does a full side prevent panning on that axis.
    let baselineFootprint = adjustmentSession.baselineCrop.cropExtent
    let currentFootprint = currentCrop.cropExtent
    var footprint = cropExtent
    let epsilon: CGFloat = 1e-8

    if baselineFootprint.width
      >= adjustmentSession.baselineCrop.imageSize.width - epsilon
      && currentFootprint.width >= currentCrop.imageSize.width - epsilon
    {
      footprint.origin.x = 0
      footprint.size.width = currentCrop.imageSize.width
    }

    if baselineFootprint.height
      >= adjustmentSession.baselineCrop.imageSize.height - epsilon
      && currentFootprint.height >= currentCrop.imageSize.height - epsilon
    {
      footprint.origin.y = 0
      footprint.size.height = currentCrop.imageSize.height
    }

    return footprint
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
  }

  private func endScrollViewAdjustment(_ kind: ScrollViewAdjustmentKind) {
    guard scrollViewAdjustmentSession?.kind == kind else {
      debugLogScrollViewAdjustment("\(kind)-end ignored")
      return
    }

    didChangeScrollView()
  }

  private var isZoomInteractionActive: Bool {
    if scrollViewAdjustmentKind == .zoom {
      return true
    }
    return cropSurface.isZoomInteractionActive
  }

  private func didSettleScrollViewAdjustment() {
    debugLogScrollViewAdjustment("settle-begin")

    let recordedCrop = record(bounds: .translating)

    var restoredBaselineCrop = false
    if
      let baselineCrop = scrollViewAdjustmentSession?.baselineCrop,
      let recordedCrop,
      baselineCrop.isPixelEquivalent(to: recordedCrop)
    {
      restoredBaselineCrop = updateProposedCrop(baselineCrop)
    }

    debugLogScrollViewAdjustment("settle-end")

    scrollViewAdjustmentSession = nil

    // The one layout after a scroll gesture, now that proposedCrop is the
    // crop the gesture left on screen. A guide resize in progress lays out
    // when it ends.
    guard
      isCropEditing || restoredBaselineCrop,
      guideView.interaction.contains(.resizingGuide) == false
    else {
      return
    }
    updateCropLayout()
  }

  /// Records the scroll adjustment once the scroll view rests.
  ///
  /// A rest outside the scroll range is checked once more, in case UIKit
  /// is about to bounce it back; if it stays there, the guide is recorded
  /// with its size and moved inside the image, and the layout after it moves
  /// the image back under the guide. Waiting longer would leave the
  /// adjustment unrecorded until the next gesture.
  @inline(__always)
  private func didChangeScrollView(hasWaitedOutsideScrollRange: Bool = false) {
    debugLogScrollViewAdjustment("settle-scheduled")

    scrollViewSettleDebounce.on { [weak self] in
      guard let self else { return }

      self.debugLogScrollViewAdjustment("settle-check")

      let scrollView = self.cropSurface.scrollView
      guard scrollView.isScrollMotionQuiet else {
        self.didChangeScrollView()
        return
      }

      guard scrollView.isContentOffsetInScrollRange || hasWaitedOutsideScrollRange else {
        self.didChangeScrollView(hasWaitedOutsideScrollRange: true)
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
    // Foregrounding may need a fresh drawable without changing image inputs.
    cropSurface.canvasView?.setNeedsCanvasDisplay()
    toolSurface.canvasView?.setNeedsCanvasDisplay()
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

    let surface: CanvasSurface = isCropEditing ? cropSurface : toolSurface
    let layers = displayLayers(for: surface)
    if clipsToGuide {
      let clipRect = layers.canvas.convert(layers.clip.bounds, from: layers.clip)
      surfaceHost.updateCanvasClip(clipRect)
    } else {
      surfaceHost.updateCanvasClip(nil)
    }

    if isCropEditing {
      toolSurface.hideCanvasView()
      guard let crop = state.proposedCrop else { return }
      // The guide frames the crop output, including while it is dragged
      // (the platter keeps the settled frame), so the pass follows it.
      let guideFrame = layers.canvas.convert(layers.guide.bounds, from: layers.guide)
      cropSurface.draw(
        viewport: makeDisplayViewport(
          for: cropSurface, layers: layers, contentSize: crop.imageSize,
          contentToZoomingScale: crop.imageToPlatterScale()
        ),
        postCrop: CanvasPostCrop(
          effect: feature.canvasPostCropEffect,
          guideFrame: guideFrame,
          imageSize: crop.imageSize
        )
      )
    } else {
      cropSurface.hideCanvasView()
      guard let geometry = toolSurface.outputGeometry else { return }
      let viewport = makeDisplayViewport(
        for: toolSurface, layers: layers, contentSize: geometry.outputSize, contentToZoomingScale: 1
      )
      toolSurface.draw(
        viewport: viewport,
        postCrop: viewport.flatMap {
          CanvasPostCrop(effect: feature.canvasPostCropEffect, geometry: geometry, viewport: $0)
        }
      )
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

extension CanvasViewport {
  var editingCanvasViewport: EditingCanvasRenderer.Viewport {
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
    isScrollMotionQuiet && isContentOffsetInScrollRange
  }

  /// No touch, deceleration, zoom, or zoom bounce is moving the content.
  fileprivate var isScrollMotionQuiet: Bool {
    isDragging == false
      && isTracking == false
      && isDecelerating == false
      && isZooming == false
      && isZoomBouncing == false
  }

  /// The offset lies within the scroll range, give or take half a point.
  fileprivate var isContentOffsetInScrollRange: Bool {
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

      EditorLog.debug(.editingCanvas, """
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

extension EditingCanvasView: UIGestureRecognizerDelegate {

  /// Sets what canvas gestures edit; nil views the output only.
  ///
  /// Leaving crop editing commits the visible crop to the feature first.
  /// `.localBlur` paints only while the feature's local blur is paintable
  /// (`ImageEditorFeature.isLocalBlurPaintable`); otherwise it views the
  /// output only.
  func setEditingTarget(_ target: ImageEditorCanvas.Target?) {
    guard editingTarget != target else {
      return
    }

    let leavesCropEditing = isCropEditing && target != .crop
    if leavesCropEditing, state.proposedCrop != nil {
      // Leaving crop editing commits the proposed crop before
      // the tool surface derives its display geometry.
      applyPendingCrop()
    }

    editingTarget = target

    applySurfaceMode(syncsToolViewportFromCrop: leavesCropEditing)
    updateDisplay()
  }

  func setBrush(_ brush: ImageEditorCanvas.Brush) {
    guard self.brush != brush else {
      return
    }
    let smoothingChanged = self.brush.smoothing != brush.smoothing
    self.brush = brush
    guard smoothingChanged else {
      refreshCanvasBrushIfNeeded()
      return
    }
    // A smoothing change must reach the surfaces even when the resolved
    // image-space brush is unchanged.
    let resolved = canvasBrush
    appliedCanvasBrush = resolved
    cropSurface.configureCanvas(brush: resolved, smoothing: brush.smoothing)
    toolSurface.configureCanvas(brush: resolved, smoothing: brush.smoothing)
  }

  /// The masking brush resolved into pre-final-crop image pixels using the
  /// view's current geometry. Mirrors the tool surface's minimum-zoom fit;
  /// `contentInset` does not participate there.
  private var canvasBrush: EditingCanvasBrush {
    let imageDiameter: CGFloat
    switch brush.diameter {
    case .imagePixels(let value):
      imageDiameter = value
    case .viewportPoints(let value):
      imageDiameter = ImageEditorCanvas.Brush.imageSpaceDiameter(
        pointDiameter: value,
        viewportSize: bounds.size,
        crop: feature.crop
      )
    }
    return .init(
      size: Double(imageDiameter),
      hardness: brush.hardness,
      opacity: brush.opacity,
      spacing: brush.spacing
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
    cropSurface.configureCanvas(brush: resolved, smoothing: brush.smoothing)
    toolSurface.configureCanvas(brush: resolved, smoothing: brush.smoothing)
  }

  /// Applies the active surface's visibility, interaction, and viewport wiring.
  ///
  /// - Parameter syncsToolViewportFromCrop: Pass true when transitioning from
  ///   Crop mode into a Tool mode so viewport-only crop scroll changes are not
  ///   mistaken for reusable Tool scroll state.
  private func applySurfaceMode(syncsToolViewportFromCrop: Bool = false) {
    let isCropMode = isCropEditing
    let isDrawingEnabled = isMaskEditing

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

  /// Commits a finished brush stroke into the blur mask.
  ///
  /// The stroke arrives in the tool canvas's crop-output space. It is mapped
  /// into the pre-crop source space and then, in the one conversion, into the
  /// feature's working space.
  func commitCanvasStroke(
    record: EditingCanvasStrokeRecord,
    completion: @escaping () -> Void
  ) {
    guard
      isMaskEditing,
      let crop = state.proposedCrop,
      let geometry = EditingCanvasCropOutputGeometry(crop: crop)
    else {
      completion()
      return
    }

    let sourceRecord = geometry.sourceRecord(fromOutputRecord: record)
    let stroke = sourceRecord.workingSpaceStroke(domainHeight: source.imageSize.height)

    commitFeatureChange { feature in
      feature.appendLocalBlurStroke(stroke)
    }
    completion()
  }

  /// Pushes the committed strokes to both surfaces, including the hidden one.
  private func syncCommittedStrokesFromFeature() {
    let domainHeight = source.imageSize.height

    cropSurface.setCommittedStrokes(
      committedStrokeRecords.sourceRecords(
        localBlur: feature.localBlur,
        domainHeight: domainHeight
      )
    )

    guard
      let crop = state.proposedCrop,
      let geometry = EditingCanvasCropOutputGeometry(crop: crop)
    else {
      return
    }

    toolSurface.setCommittedStrokes(
      committedStrokeRecords.outputRecords(
        localBlur: feature.localBlur,
        geometry: geometry,
        domainHeight: domainHeight
      )
    )
  }
}

extension EditingCanvasView {

  /// Memoized canvas records for the committed blur-mask strokes.
  ///
  /// Mapping every stamp (working space to canvas, then into the crop
  /// output) is linear in the painted stamps, and `updateDisplay()` runs on
  /// every host update. An unchanged mask compares equal cheaply (its stroke
  /// arrays are shared), and returning the same record arrays lets the
  /// canvas renderer's own equality check short-circuit too.
  struct CommittedStrokeRecords {

    private var source: (
      localBlur: LocalAdjustmentFeature<GaussianBlurFeature>?,
      records: [EditingCanvasStrokeRecord]
    )?

    private var output: (
      localBlur: LocalAdjustmentFeature<GaussianBlurFeature>?,
      geometry: EditingCanvasCropOutputGeometry,
      records: [EditingCanvasStrokeRecord]
    )?

    /// Records in the source domain (y-down), for a canvas sized to the
    /// source image.
    mutating func sourceRecords(
      localBlur: LocalAdjustmentFeature<GaussianBlurFeature>?,
      domainHeight: CGFloat
    ) -> [EditingCanvasStrokeRecord] {
      if let source, source.localBlur == localBlur {
        return source.records
      }
      let records = CanvasRenderPlan(localBlur: localBlur)
        .committedStrokes(in: nil, domainHeight: domainHeight)
      source = (localBlur, records)
      return records
    }

    /// Records in the crop-output domain of `geometry`, for the tool canvas.
    mutating func outputRecords(
      localBlur: LocalAdjustmentFeature<GaussianBlurFeature>?,
      geometry: EditingCanvasCropOutputGeometry,
      domainHeight: CGFloat
    ) -> [EditingCanvasStrokeRecord] {
      if let output, output.localBlur == localBlur, output.geometry == geometry {
        return output.records
      }
      let records = sourceRecords(localBlur: localBlur, domainHeight: domainHeight).map {
        geometry.outputRecord(fromSourceRecord: $0)
      }
      output = (localBlur, geometry, records)
      return records
    }
  }
}
