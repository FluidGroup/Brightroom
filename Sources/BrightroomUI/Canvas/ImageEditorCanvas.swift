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
import SwiftUI
import BrightroomEngine
import BrightroomParametric

public struct ImageEditorCanvas: View {

  public final class ResetAction {

    var onCall: () -> Void = {}

    public init() {

    }

    public func callAsFunction() {
      onCall()
    }
  }

  public final class RotateAction {

    var onCall: () -> Void = {}

    public init() {

    }

    public func callAsFunction() {
      onCall()
    }
  }

  public final class ApplyAction {

    var onCall: () -> Void = {}

    public init() {

    }

    public func callAsFunction() {
      onCall()
    }
  }

  /// Commits the current live straighten angle into EditingCanvasView's recorded crop
  /// geometry.
  ///
  /// Use this from controls that stream `straightenAngle` while dragging but
  /// only want to record the crop extent after the interaction settles.
  public final class AdjustmentAngleCommitAction {

    var onCall: (Angle) -> Void = { _ in }

    public init() {

    }

    public func callAsFunction(_ angle: Angle) {
      onCall(angle)
    }
  }

  /// Applies a canvas change to the binding's latest document.
  ///
  /// A change from a canvas prepared for another image is dropped: its crop
  /// and strokes are pixel coordinates of that image, so applying them to
  /// this document would corrupt it. That happens when the host replaces the
  /// document with one of another image while a change is still queued.
  @MainActor
  static func apply(
    _ change: EditingCanvasView.FeatureChange,
    preparedFor source: SourceImage,
    to document: Binding<ImageEditorDocument>
  ) {
    var next = document.wrappedValue
    guard next.source == source else {
      return
    }
    change(&next.feature)
    // Writing an equal value would still invalidate the host's views.
    if next != document.wrappedValue {
      document.wrappedValue = next
    }
  }

  /// Fixed at creation. See the initializer documentation.
  private let cropInsideOverlay: ((CropInteraction?) -> AnyView)?

  /// Fixed at creation. See the initializer documentation.
  private let cropOutsideOverlay: ((CropInteraction?) -> AnyView)?

  private let document: Binding<ImageEditorDocument>

  /// The loader a built-in editor shares with its other views; nil when the
  /// view prepares the document's source image itself.
  private let previewSourceLoader: PreviewSourceLoader?

  /// A feature a built-in editor shows in place of `document.feature`, such
  /// as a slider value not yet written; nil shows the document.
  private let displayedFeature: ImageEditorFeature?

  private var quarterTurnInput: Binding<QuarterTurn?> = .constant(nil)
  private var straightenAngleInput: Binding<Angle?> = .constant(nil)
  private var lockedAspectRatioInput: Binding<AspectRatio?> = .constant(nil)
  private var _resetAction: ResetAction?
  private var _rotateAction: RotateAction?
  private var _applyAction: ApplyAction?
  private var _adjustmentAngleCommitAction: AdjustmentAngleCommitAction?

  private var onCropGuideChange: (@MainActor (CropGuide) -> Void)?
  private var isCropGuideDisabled = false
  private let areAnimationsEnabled: Bool
  private var clipsToGuide: Bool = false
  /// Fixed at creation. See the initializer documentation.
  private let contentInsets: EdgeInsets?
  private var editingTarget: ImageEditorCanvas.Target? = .crop
  private var brush: Brush = .init(diameter: .viewportPoints(30))

  /// Creates a crop canvas that edits `document`, with custom overlays.
  ///
  /// The view prepares the document's source image for display and shows a
  /// progress indicator until it is ready, or a failure message when the
  /// image's pixels cannot be decoded (the document is left untouched). Changes made on the canvas (crop
  /// commits through `ApplyAction` or when leaving crop editing, and brush
  /// strokes) are applied to the binding's latest document's `feature`; the
  /// view never commits them to the history, so call `commit()` when a change
  /// should become an undo step. A document set from outside (for example an
  /// undo) is displayed, and its crop reloads the crop guide. A document of
  /// another image rebuilds the canvas.
  ///
  /// A host that sets `document.localBlur` with its own blur before the first
  /// stroke pays for that blur at export until a stroke lands. The canvas
  /// previews a blur mask only when its tree is rooted at a brush, which is
  /// the shape the view authors; another root renders at export only.
  ///
  /// - Parameters:
  ///   - document: The edited document.
  ///   - areAnimationsEnabled: Applied on every update.
  ///   - contentInsets: **Fixed at creation.** The canvas reads the insets,
  ///     and the layout direction that resolves their leading and trailing
  ///     edges, once when it is mounted; later values are ignored. A host
  ///     that derives the insets from safe area or size class must give this
  ///     view a new identity (for example with `.id`) for new insets to take
  ///     effect.
  ///   - cropInsideOverlay: **Fixed at creation.** The builder is invoked by
  ///     the mounted canvas, but the closure itself is installed only once, so
  ///     values it captures are frozen at that point.
  ///   - cropOutsideOverlay: **Fixed at creation.** Same contract as
  ///     `cropInsideOverlay`.
  public init<InsideOverlay: View, OutsideOverlay: View>(
    document: Binding<ImageEditorDocument>,
    areAnimationsEnabled: Bool = true,
    contentInsets: EdgeInsets? = nil,
    @ViewBuilder cropInsideOverlay: @escaping (CropInteraction?) -> InsideOverlay,
    @ViewBuilder cropOutsideOverlay: @escaping (CropInteraction?) -> OutsideOverlay
  ) {
    self.document = document
    self.previewSourceLoader = nil
    self.displayedFeature = nil
    self.areAnimationsEnabled = areAnimationsEnabled
    self.contentInsets = contentInsets
    self.cropInsideOverlay = { AnyView(cropInsideOverlay($0)) }
    self.cropOutsideOverlay = { AnyView(cropOutsideOverlay($0)) }
  }

  /// Creates a crop canvas that edits `document`, with the built-in
  /// overlays.
  ///
  /// See `init(document:areAnimationsEnabled:contentInsets:cropInsideOverlay:cropOutsideOverlay:)`
  /// for how the document is written back and displayed.
  ///
  /// - Parameters:
  ///   - document: The edited document.
  ///   - areAnimationsEnabled: Applied on every update.
  ///   - contentInsets: **Fixed at creation.** The canvas reads the insets,
  ///     and the layout direction that resolves their leading and trailing
  ///     edges, once when it is mounted; later values are ignored. A host
  ///     that derives the insets from safe area or size class must give this
  ///     view a new identity (for example with `.id`) for new insets to take
  ///     effect.
  public init(
    document: Binding<ImageEditorDocument>,
    areAnimationsEnabled: Bool = true,
    contentInsets: EdgeInsets? = nil
  ) {
    self.cropInsideOverlay = nil
    self.cropOutsideOverlay = nil
    self.document = document
    self.previewSourceLoader = nil
    self.displayedFeature = nil
    self.areAnimationsEnabled = areAnimationsEnabled
    self.contentInsets = contentInsets
  }

  /// Creates a crop canvas with the built-in overlays over a loader a
  /// built-in editor already shares for `document`'s source image.
  ///
  /// - Parameter displayedFeature: Shown in place of `document.feature` while
  ///   non-nil. It must differ from the document only in what the editor has
  ///   not written yet (slider values); canvas changes still apply to the
  ///   document.
  init(
    document: Binding<ImageEditorDocument>,
    displayedFeature: ImageEditorFeature?,
    previewSourceLoader: PreviewSourceLoader
  ) {
    self.cropInsideOverlay = nil
    self.cropOutsideOverlay = nil
    self.document = document
    self.displayedFeature = displayedFeature
    self.previewSourceLoader = previewSourceLoader
    self.areAnimationsEnabled = true
    self.contentInsets = nil
  }

  public var body: some View {
    let source = document.wrappedValue.source
    if let previewSourceLoader, previewSourceLoader.source == source {
      canvas(previewSourceLoader: previewSourceLoader)
    } else {
      // A new identity per source image: the owned loader, and the canvas bound
      // to it, are rebuilt when the host switches to a document of another image.
      PreviewSourceReader(source: source) { loader in
        canvas(previewSourceLoader: loader)
      }
      .id(source)
    }
  }

  private func canvas(previewSourceLoader: PreviewSourceLoader) -> some View {
    ZStack {
      switch previewSourceLoader.phase {
      case .loaded(let previewSource):
        EditingCanvasRepresentable(
          source: EditingCanvasSource(previewSource),
          feature: displayedFeature ?? document.wrappedValue.feature,
          onFeatureChange: { [document] change in
            Self.apply(change, preparedFor: previewSource.source, to: document)
          },
          cropInsideOverlay: cropInsideOverlay,
          cropOutsideOverlay: cropOutsideOverlay,
          quarterTurnInput: quarterTurnInput,
          straightenAngleInput: straightenAngleInput,
          lockedAspectRatioInput: lockedAspectRatioInput,
          resetAction: _resetAction,
          rotateAction: _rotateAction,
          applyAction: _applyAction,
          adjustmentAngleCommitAction: _adjustmentAngleCommitAction,
          onCropGuideChange: onCropGuideChange,
          isCropGuideDisabled: isCropGuideDisabled,
          areAnimationsEnabled: areAnimationsEnabled,
          clipsToGuide: clipsToGuide,
          contentInsets: contentInsets,
          editingTarget: editingTarget,
          brush: brush
        )
        // `EditingCanvasView` binds its source once, at creation. Tying the
        // representable's identity to the image makes an image swap rebuild
        // the canvas instead of leaving it bound to the old image.
        .id(previewSource.source)
        .transition(.opacity.animation(.smooth))
      case .failed:
        // Nothing to edit; the host's own controls stay the way out.
        ContentUnavailableView(
          "The image could not be loaded",
          systemImage: "exclamationmark.triangle"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity.animation(.smooth))
      case .idle, .loading:
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .transition(.opacity.animation(.smooth))
      }
    }
    .task {
      await previewSourceLoader.load()
    }
  }

  /// Calls `action` with the crop guide each time it changes: when the user
  /// moves or resizes it, when the canvas loads or reloads the document's
  /// crop (for example after an undo), and when an input or a command
  /// changes it.
  ///
  /// A change made outside a SwiftUI view update (a gesture or a command) is
  /// reported at once, so the guide is current when the command returns. A
  /// change made while SwiftUI updates the canvas (mounting it, displaying a
  /// new document, or applying an input) is reported on the next main-actor
  /// turn, so `action` can write to state; only the latest guide is
  /// reported. A guide equal to the last one reported is not reported
  /// again. The latest `action` is used; it is re-bound on every update.
  public consuming func onCropGuideChange(
    _ action: @escaping @MainActor (CropGuide) -> Void
  ) -> Self {
    self.onCropGuideChange = action
    return self
  }

  /// Sets whether the crop guide ignores touches. The image can still be
  /// moved and zoomed under the guide to change the crop. The guide is
  /// interactive by default; the value is applied on every update.
  public consuming func cropGuideDisabled(_ disabled: Bool = true) -> Self {
    self.isCropGuideDisabled = disabled
    return self
  }

  /// Sets whether the image canvas is clipped to the crop guide.
  ///
  /// Clipping is disabled by default. Changes are applied to the mounted
  /// canvas on each update.
  public consuming func clipsToGuide(_ clipsToGuide: Bool) -> Self {
    self.clipsToGuide = clipsToGuide
    return self
  }

  /// Sets the output's quarter turn; nil leaves the canvas's turn as it is.
  public consuming func quarterTurn(_ turn: QuarterTurn?) -> Self {
    self.quarterTurnInput = .constant(turn)
    return self
  }

  /// Sets the output's quarter turn, and writes the canvas's turn back to the
  /// binding when the rotate action or a reloaded crop changes it.
  public consuming func quarterTurn(_ turn: Binding<QuarterTurn?>) -> Self {
    self.quarterTurnInput = turn
    return self
  }

  /// Sets the straighten angle: the free rotation applied before cropping.
  /// nil leaves the canvas's angle as it is.
  public consuming func straightenAngle(_ angle: Angle?) -> Self {
    self.straightenAngleInput = .constant(angle)
    return self
  }

  /// Sets the straighten angle, and writes the canvas's angle back to the
  /// binding when a gesture or a reloaded crop changes it.
  public consuming func straightenAngle(_ angle: Binding<Angle?>) -> Self {
    self.straightenAngleInput = angle
    return self
  }

  public consuming func registerAdjustmentAngleCommitAction(_ action: AdjustmentAngleCommitAction) -> Self {
    self._adjustmentAngleCommitAction = action
    return self
  }

  /// Locks the crop guide to an aspect ratio in the output orientation; nil
  /// unlocks it.
  public consuming func lockedAspectRatio(_ ratio: AspectRatio?) -> Self {
    self.lockedAspectRatioInput = .constant(ratio)
    return self
  }

  /// Locks the crop guide to an aspect ratio, and writes the canvas's locked
  /// ratio back to the binding when it changes.
  public consuming func lockedAspectRatio(_ ratio: Binding<AspectRatio?>) -> Self {
    self.lockedAspectRatioInput = ratio
    return self
  }

  /// Sets which part of the feature the canvas's gestures edit (the
  /// adjustment point); nil views the output only. The default is `.crop`.
  ///
  /// Leaving `.crop` commits the visible crop to the document.
  public consuming func editingTarget(_ target: Target?) -> Self {
    self.editingTarget = target
    return self
  }

  /// Sets the brush that paints `localBlur`, including how its strokes are
  /// smoothed. The diameter may be authored in viewport points or image
  /// pixels; the canvas resolves it against its own geometry.
  public consuming func brush(_ brush: Brush) -> Self {
    self.brush = brush
    return self
  }

  public consuming func registerResetAction(_ action: ResetAction) -> Self {

    self._resetAction = action
    return self

  }

  public consuming func registerRotateAction(_ action: RotateAction) -> Self {

    self._rotateAction = action
    return self

  }

  public consuming func registerApplyAction(_ action: ApplyAction) -> Self {

    self._applyAction = action
    return self

  }

}

/// Hosts an `EditingCanvasView` once the image and the document are available.
///
/// Internal (not private) so tests can drive its coordinator.
struct EditingCanvasRepresentable: UIViewRepresentable {

  let source: EditingCanvasSource
  let feature: ImageEditorFeature
  let onFeatureChange: @MainActor (_ change: EditingCanvasView.FeatureChange) -> Void
  let cropInsideOverlay: ((CropInteraction?) -> AnyView)?
  let cropOutsideOverlay: ((CropInteraction?) -> AnyView)?
  let quarterTurnInput: Binding<QuarterTurn?>
  let straightenAngleInput: Binding<Angle?>
  let lockedAspectRatioInput: Binding<AspectRatio?>
  let resetAction: ImageEditorCanvas.ResetAction?
  let rotateAction: ImageEditorCanvas.RotateAction?
  let applyAction: ImageEditorCanvas.ApplyAction?
  let adjustmentAngleCommitAction: ImageEditorCanvas.AdjustmentAngleCommitAction?
  let onCropGuideChange: (@MainActor (ImageEditorCanvas.CropGuide) -> Void)?
  let isCropGuideDisabled: Bool
  let areAnimationsEnabled: Bool
  let clipsToGuide: Bool
  let contentInsets: EdgeInsets?
  let editingTarget: ImageEditorCanvas.Target?
  let brush: ImageEditorCanvas.Brush

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeUIView(context: Context) -> EditingCanvasView {
    let view: EditingCanvasView
    if let contentInsets {
      let isRightToLeft = context.environment.layoutDirection == .rightToLeft
      view = .init(
        source: source,
        feature: feature,
        contentInset: UIEdgeInsets(
          top: contentInsets.top,
          left: isRightToLeft ? contentInsets.trailing : contentInsets.leading,
          bottom: contentInsets.bottom,
          right: isRightToLeft ? contentInsets.leading : contentInsets.trailing
        )
      )
    } else {
      view = .init(source: source, feature: feature)
    }

    view.isGuideInteractionEnabled = isCropGuideDisabled == false
    view.areAnimationsEnabled = areAnimationsEnabled
    view.clipsToGuide = clipsToGuide
    view.setBrush(brush)
    // The target is set before loading, so loading never runs the "leave
    // crop editing" commit against an unloaded view.
    view.setEditingTarget(editingTarget)
    bindCropGuideHandler(to: view, coordinator: context.coordinator)
    bindFeatureChangeHandler(to: view, coordinator: context.coordinator)

    // `contentInsets` above and the two overlays below are creation-only inputs,
    // as documented on ImageEditorCanvas's initializers. `updateUIView`
    // deliberately does not re-apply them: `contentInset` is a `let` on
    // EditingCanvasView, and re-installing `AnyView` overlay closures on every update
    // would rebuild the hosted overlays for no gain. Wiring live overlays would
    // need an explicit change token, not an unconditional re-set.
    if let cropInsideOverlay {
      view.setCropInsideOverlay(EditingCanvasView.SwiftUICropInsideOverlay(content: cropInsideOverlay))
    }

    if let cropOutsideOverlay {
      view.setCropOutsideOverlay(EditingCanvasView.SwiftUICropOutsideOverlay(content: cropOutsideOverlay))
    }

    configureActions(on: view)
    context.coordinator.applySwiftUIInputs {
      view.loadFeature()
    }

    return view
  }

  func updateUIView(_ canvasView: EditingCanvasView, context: Context) {
    bindCropGuideHandler(to: canvasView, coordinator: context.coordinator)
    bindFeatureChangeHandler(to: canvasView, coordinator: context.coordinator)

    if canvasView.isGuideInteractionEnabled == isCropGuideDisabled {
      canvasView.isGuideInteractionEnabled = isCropGuideDisabled == false
    }

    if canvasView.areAnimationsEnabled != areAnimationsEnabled {
      canvasView.areAnimationsEnabled = areAnimationsEnabled
    }

    // Everything that pushes SwiftUI inputs into EditingCanvasView runs inside the
    // guard. `setFeature` and `setEditingTarget` can report a crop guide
    // or a feature change synchronously, and an unguarded one writes the
    // host's state from inside `updateUIView` — a state mutation during
    // view update. The coordinator defers both. `setBrush` cannot emit
    // today; it is inside for a uniform contract, so a future emitting setter
    // is safe by default.
    //
    // Order matters:
    // - The quarter-turn and angle inputs run before `setFeature`. They mirror
    //   the proposed crop through deferred crop guides, so when `setFeature`
    //   reloads the crop (an undo), they still hold the previous values and
    //   would otherwise rotate the reloaded crop back.
    // - `setFeature` runs before `setEditingTarget`. When an undo and a
    //   switch away from `.crop` arrive together, the crop reloads first, and
    //   leaving `.crop` then commits nothing over the host's undo.
    // - While feature changes are queued, the owner still holds the
    //   feature from before them, so they are applied to it for display.
    context.coordinator.applySwiftUIInputs {
      if canvasView.clipsToGuide != clipsToGuide {
        canvasView.clipsToGuide = clipsToGuide
      }

      if let quarterTurn = quarterTurnInput.wrappedValue {
        canvasView.setQuarterTurn(quarterTurn)
      }

      if let straightenAngle = straightenAngleInput.wrappedValue {
        canvasView.setStraightenAngle(
          straightenAngle,
          recordsCropExtent: adjustmentAngleCommitAction == nil
        )
      }

      canvasView.setLockedAspectRatio(lockedAspectRatioInput.wrappedValue)

      canvasView.setBrush(brush)

      // Also refreshes the display for the inputs above.
      canvasView.setFeature(context.coordinator.applyingPendingFeatureChanges(to: feature))
      canvasView.setEditingTarget(editingTarget)
    }

    configureActions(on: canvasView)
  }

  @MainActor
  private func bindCropGuideHandler(to canvasView: EditingCanvasView, coordinator: Coordinator) {
    coordinator.bindCropGuideHandler(
      to: canvasView,
      syncInputs: { guide in
        syncInputs(with: guide)
      },
      onCropGuideChange: onCropGuideChange ?? { _ in }
    )
  }

  @MainActor
  private func bindFeatureChangeHandler(to canvasView: EditingCanvasView, coordinator: Coordinator) {
    coordinator.bindFeatureChangeHandler(
      to: canvasView,
      onFeatureChange: onFeatureChange
    )
  }

  @MainActor
  private func configureActions(on canvasView: EditingCanvasView) {
    resetAction?.onCall = { [weak canvasView] in
      guard let canvasView else { return }

      canvasView.resetCrop()
    }

    rotateAction?.onCall = { [weak canvasView] in
      guard let canvasView else { return }

      canvasView.rotateCounterclockwise()
    }

    applyAction?.onCall = { [weak canvasView] in
      canvasView?.applyPendingCrop()
    }

    adjustmentAngleCommitAction?.onCall = { [weak canvasView] angle in
      canvasView?.commitStraightenAngle(angle)
    }
  }

  @MainActor
  private func syncInputs(with guide: ImageEditorCanvas.CropGuide) {
    if let crop = guide.pendingCrop {
      quarterTurnInput.setIfChanged(crop.quarterTurn)
      straightenAngleInput.setIfChanged(Angle(radians: crop.straightenRadians))
    }
    lockedAspectRatioInput.setIfChanged(guide.lockedAspectRatio)
  }

  @MainActor
  final class Coordinator {

    private var isApplyingSwiftUIInputs = false
    private var pendingInputSyncGuide: ImageEditorCanvas.CropGuide?

    private var onCropGuideChange: @MainActor (ImageEditorCanvas.CropGuide) -> Void = { _ in }

    /// The crop guide reported while SwiftUI inputs were being applied, not
    /// yet delivered; only the latest is kept.
    private var pendingCropGuide: ImageEditorCanvas.CropGuide?

    /// The last crop guide delivered to `onCropGuideChange`, so an equal one
    /// is not delivered again.
    private var lastDeliveredCropGuide: ImageEditorCanvas.CropGuide?

    /// Feature changes emitted while SwiftUI inputs were being applied, not
    /// yet applied by the owner, in emission order.
    ///
    /// Until they are delivered, the owner still holds the feature from
    /// before them; `updateUIView` displays them applied to it so EditingCanvasView
    /// does not reload the stale crop.
    private var pendingFeatureChanges: [EditingCanvasView.FeatureChange] = []

    private var onFeatureChange: @MainActor (_ change: EditingCanvasView.FeatureChange) -> Void = { _ in }

    /// Routes EditingCanvasView's feature changes to `onFeatureChange`, re-bound on
    /// every update because the host's destination can change.
    func bindFeatureChangeHandler(
      to canvasView: EditingCanvasView,
      onFeatureChange: @escaping @MainActor (_ change: EditingCanvasView.FeatureChange) -> Void
    ) {
      self.onFeatureChange = onFeatureChange
      canvasView.setFeatureChangeHandler { [weak self] change in
        self?.deliverFeatureChange(change)
      }
    }

    /// Applies a change to the owner's feature: now, or on the next
    /// main-actor turn when it was emitted while SwiftUI inputs were being
    /// applied. Changes are delivered in emission order.
    func deliverFeatureChange(_ change: @escaping EditingCanvasView.FeatureChange) {
      if isApplyingSwiftUIInputs {
        if pendingFeatureChanges.isEmpty {
          schedulePendingFeatureDelivery()
        }
        pendingFeatureChanges.append(change)
      } else {
        deliverPendingFeatureChanges()
        onFeatureChange(change)
      }
    }

    /// `feature` with the undelivered changes applied.
    func applyingPendingFeatureChanges(to feature: ImageEditorFeature) -> ImageEditorFeature {
      var feature = feature
      for change in pendingFeatureChanges {
        change(&feature)
      }
      return feature
    }

    private func deliverPendingFeatureChanges() {
      let changes = pendingFeatureChanges
      pendingFeatureChanges = []
      for change in changes {
        onFeatureChange(change)
      }
    }

    private func schedulePendingFeatureDelivery() {
      Task { @MainActor [weak self] in
        guard let self else { return }

        if self.isApplyingSwiftUIInputs {
          self.schedulePendingFeatureDelivery()
          return
        }

        self.deliverPendingFeatureChanges()
      }
    }

    /// Routes EditingCanvasView's crop guides to the input sync and to
    /// `onCropGuideChange`, re-bound on every update because the host's
    /// destinations can change.
    func bindCropGuideHandler(
      to canvasView: EditingCanvasView,
      syncInputs: @escaping @MainActor (ImageEditorCanvas.CropGuide) -> Void,
      onCropGuideChange: @escaping @MainActor (ImageEditorCanvas.CropGuide) -> Void
    ) {
      self.onCropGuideChange = onCropGuideChange
      canvasView.setCropGuideHandler { [weak self] guide in
        guard let self else { return }

        self.syncInputs(with: guide, syncInputs)
        self.deliverCropGuide(guide)
      }
    }

    func applySwiftUIInputs(_ body: () -> Void) {
      isApplyingSwiftUIInputs = true
      defer {
        isApplyingSwiftUIInputs = false
      }

      body()
    }

    /// Delivers a crop guide to `onCropGuideChange`: now, or on the next
    /// main-actor turn when it was reported while SwiftUI inputs were being
    /// applied, keeping only the latest. A guide equal to the last one
    /// delivered is dropped.
    func deliverCropGuide(_ guide: ImageEditorCanvas.CropGuide) {
      if isApplyingSwiftUIInputs {
        if pendingCropGuide == nil {
          schedulePendingCropGuideDelivery()
        }
        pendingCropGuide = guide
      } else {
        // A newer guide supersedes the pending one.
        pendingCropGuide = nil
        deliverCropGuideIfChanged(guide)
      }
    }

    private func deliverCropGuideIfChanged(_ guide: ImageEditorCanvas.CropGuide) {
      guard guide != lastDeliveredCropGuide else {
        return
      }
      lastDeliveredCropGuide = guide
      onCropGuideChange(guide)
    }

    private func schedulePendingCropGuideDelivery() {
      Task { @MainActor [weak self] in
        guard let self else { return }

        if self.isApplyingSwiftUIInputs {
          self.schedulePendingCropGuideDelivery()
          return
        }

        guard let guide = self.pendingCropGuide else {
          return
        }

        self.pendingCropGuide = nil
        self.deliverCropGuideIfChanged(guide)
      }
    }

    private func syncInputs(
      with guide: ImageEditorCanvas.CropGuide,
      _ syncInputs: @escaping @MainActor (ImageEditorCanvas.CropGuide) -> Void
    ) {
      if isApplyingSwiftUIInputs {
        pendingInputSyncGuide = guide
        schedulePendingInputSync(syncInputs)
      } else {
        syncInputs(guide)
      }
    }

    private func schedulePendingInputSync(
      _ syncInputs: @escaping @MainActor (ImageEditorCanvas.CropGuide) -> Void
    ) {
      Task { @MainActor [weak self] in
        guard let self else { return }

        if self.isApplyingSwiftUIInputs {
          self.schedulePendingInputSync(syncInputs)
          return
        }

        guard let guide = self.pendingInputSyncGuide else {
          return
        }

        self.pendingInputSyncGuide = nil
        syncInputs(guide)
      }
    }
  }

}

private extension Binding where Value: Equatable {

  @MainActor
  func setIfChanged(_ value: Value) {
    if wrappedValue != value {
      wrappedValue = value
    }
  }
}
