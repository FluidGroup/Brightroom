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

  public struct StateSnapshot: Equatable {
    public var proposedCrop: CropEditingState?
    public var frame: CGRect
    public var interaction: CropInteraction
    public var preferredAspectRatio: PixelAspectRatio?

    public init(
      proposedCrop: CropEditingState?,
      frame: CGRect,
      interaction: CropInteraction,
      preferredAspectRatio: PixelAspectRatio?
    ) {
      self.proposedCrop = proposedCrop
      self.frame = frame
      self.interaction = interaction
      self.preferredAspectRatio = preferredAspectRatio
    }
  }

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

    var onCall: (CropEditingState.AdjustmentAngle) -> Void = { _ in }

    public init() {

    }

    public func callAsFunction(_ angle: CropEditingState.AdjustmentAngle) {
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
    preparedFor image: SourceImage,
    to document: Binding<ImageEditorDocument>
  ) {
    var next = document.wrappedValue
    guard next.image == image else {
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

  /// The stack a built-in editor shares with its other views; nil when the
  /// view prepares the document's image itself.
  private let editingStack: EditingStack?

  /// A feature a built-in editor shows in place of `document.feature`, such
  /// as a slider value not yet written; nil shows the document.
  private let displayedFeature: ImageEditorFeature?

  private var rotationInput: Binding<CropEditingState.Rotation?> = .constant(nil)
  private var straightenAngleInput: Binding<Angle?> = .constant(nil)
  private var lockedAspectRatioInput: Binding<PixelAspectRatio?> = .constant(nil)
  private var _resetAction: ResetAction?
  private var _rotateAction: RotateAction?
  private var _applyAction: ApplyAction?
  private var _adjustmentAngleCommitAction: AdjustmentAngleCommitAction?

  private let stateHandler: @MainActor (StateSnapshot) -> Void
  private let isGuideInteractionEnabled: Bool
  private let areAnimationsEnabled: Bool
  private var clipsToGuide: Bool = false
  /// Fixed at creation. See the initializer documentation.
  private let contentInset: UIEdgeInsets?
  private var editingTarget: ImageEditorCanvas.Target? = .crop
  private var brush: Brush = .init(diameter: .viewportPoints(30))

  /// Creates a crop canvas that edits `document`, with custom overlays.
  ///
  /// The view prepares the document's image for display and shows a
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
  ///   - isGuideInteractionEnabled: Applied on every update.
  ///   - areAnimationsEnabled: Applied on every update.
  ///   - contentInset: **Fixed at creation.** `EditingCanvasView` stores the inset as a
  ///     `let`, so a value supplied after the canvas is mounted is ignored. A
  ///     host that derives the inset from safe area or size class must give
  ///     this view a new identity (for example with `.id`) for a new inset to
  ///     take effect.
  ///   - cropInsideOverlay: **Fixed at creation.** The builder is invoked by
  ///     the mounted canvas, but the closure itself is installed only once, so
  ///     values it captures are frozen at that point.
  ///   - cropOutsideOverlay: **Fixed at creation.** Same contract as
  ///     `cropInsideOverlay`.
  ///   - stateHandler: Re-bound on every update.
  public init<InsideOverlay: View, OutsideOverlay: View>(
    document: Binding<ImageEditorDocument>,
    isGuideInteractionEnabled: Bool = true,
    areAnimationsEnabled: Bool = true,
    contentInset: UIEdgeInsets? = nil,
    @ViewBuilder cropInsideOverlay: @escaping (CropInteraction?) -> InsideOverlay,
    @ViewBuilder cropOutsideOverlay: @escaping (CropInteraction?) -> OutsideOverlay,
    stateHandler: @escaping @MainActor (StateSnapshot) -> Void = { _ in }
  ) {
    self.document = document
    self.editingStack = nil
    self.displayedFeature = nil
    self.isGuideInteractionEnabled = isGuideInteractionEnabled
    self.areAnimationsEnabled = areAnimationsEnabled
    self.contentInset = contentInset
    self.cropInsideOverlay = { AnyView(cropInsideOverlay($0)) }
    self.cropOutsideOverlay = { AnyView(cropOutsideOverlay($0)) }
    self.stateHandler = stateHandler
  }

  /// Creates a crop canvas that edits `document`, with the built-in
  /// overlays.
  ///
  /// See `init(document:isGuideInteractionEnabled:areAnimationsEnabled:contentInset:cropInsideOverlay:cropOutsideOverlay:stateHandler:)`
  /// for how the document is written back and displayed.
  ///
  /// - Parameters:
  ///   - document: The edited document.
  ///   - isGuideInteractionEnabled: Applied on every update.
  ///   - areAnimationsEnabled: Applied on every update.
  ///   - contentInset: **Fixed at creation.** `EditingCanvasView` stores the inset as a
  ///     `let`, so a value supplied after the canvas is mounted is ignored. A
  ///     host that derives the inset from safe area or size class must give
  ///     this view a new identity (for example with `.id`) for a new inset to
  ///     take effect.
  ///   - stateHandler: Re-bound on every update.
  public init(
    document: Binding<ImageEditorDocument>,
    isGuideInteractionEnabled: Bool = true,
    areAnimationsEnabled: Bool = true,
    contentInset: UIEdgeInsets? = nil,
    stateHandler: @escaping @MainActor (StateSnapshot) -> Void = { _ in }
  ) {
    self.cropInsideOverlay = nil
    self.cropOutsideOverlay = nil
    self.document = document
    self.editingStack = nil
    self.displayedFeature = nil
    self.isGuideInteractionEnabled = isGuideInteractionEnabled
    self.areAnimationsEnabled = areAnimationsEnabled
    self.contentInset = contentInset
    self.stateHandler = stateHandler
  }

  /// Creates a crop canvas with the built-in overlays over a stack a
  /// built-in editor already prepares for `document`'s image.
  ///
  /// - Parameter displayedFeature: Shown in place of `document.feature` while
  ///   non-nil. It must differ from the document only in what the editor has
  ///   not written yet (slider values); canvas changes still apply to the
  ///   document.
  init(
    document: Binding<ImageEditorDocument>,
    displayedFeature: ImageEditorFeature?,
    editingStack: EditingStack,
    isGuideInteractionEnabled: Bool
  ) {
    self.cropInsideOverlay = nil
    self.cropOutsideOverlay = nil
    self.document = document
    self.displayedFeature = displayedFeature
    self.editingStack = editingStack
    self.isGuideInteractionEnabled = isGuideInteractionEnabled
    self.areAnimationsEnabled = true
    self.contentInset = nil
    self.stateHandler = { _ in }
  }

  public var body: some View {
    let image = document.wrappedValue.image
    if let editingStack, editingStack.image == image {
      canvas(editingStack: editingStack)
    } else {
      // A new identity per image: the owned stack, and the canvas bound to it,
      // are rebuilt when the host switches to a document of another image.
      OwnedEditingStack(image: image) { stack in
        canvas(editingStack: stack)
      }
      .id(image)
    }
  }

  private func canvas(editingStack: EditingStack) -> some View {
    ZStack {
      if let loadedState = editingStack.loadedState {
        EditingCanvasRepresentable(
          source: EditingCanvasSource(loadedState),
          feature: displayedFeature ?? document.wrappedValue.feature,
          onFeatureChange: { [document] change in
            Self.apply(change, preparedFor: loadedState.image, to: document)
          },
          cropInsideOverlay: cropInsideOverlay,
          cropOutsideOverlay: cropOutsideOverlay,
          rotationInput: rotationInput,
          straightenAngleInput: straightenAngleInput,
          lockedAspectRatioInput: lockedAspectRatioInput,
          resetAction: _resetAction,
          rotateAction: _rotateAction,
          applyAction: _applyAction,
          adjustmentAngleCommitAction: _adjustmentAngleCommitAction,
          stateHandler: stateHandler,
          isGuideInteractionEnabled: isGuideInteractionEnabled,
          areAnimationsEnabled: areAnimationsEnabled,
          clipsToGuide: clipsToGuide,
          contentInset: contentInset,
          editingTarget: editingTarget,
          brush: brush
        )
        // `EditingCanvasView` binds its source once, at creation. Tying the
        // representable's identity to the image makes an image swap rebuild
        // the canvas instead of leaving it bound to the old image.
        .id(loadedState.image)
        .transition(.opacity.animation(.smooth))
      } else if editingStack.didFailToPrepare {
        // Nothing to edit; the host's own controls stay the way out.
        ContentUnavailableView(
          "The image could not be loaded",
          systemImage: "exclamationmark.triangle"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity.animation(.smooth))
      } else {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .transition(.opacity.animation(.smooth))
      }
    }
    .onAppear {
      editingStack.start()
    }
  }

  /// Sets whether the image canvas is clipped to the crop guide.
  ///
  /// Clipping is disabled by default. Changes are applied to the mounted
  /// canvas on each update.
  public consuming func clipsToGuide(_ clipsToGuide: Bool) -> Self {
    self.clipsToGuide = clipsToGuide
    return self
  }

  public consuming func rotation(_ rotation: CropEditingState.Rotation?) -> Self {
    self.rotationInput = .constant(rotation)
    return self
  }

  public consuming func rotation(_ rotation: Binding<CropEditingState.Rotation?>) -> Self {

    self.rotationInput = rotation
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
  public consuming func lockedAspectRatio(_ ratio: PixelAspectRatio?) -> Self {
    self.lockedAspectRatioInput = .constant(ratio)
    return self
  }

  /// Locks the crop guide to an aspect ratio, and writes the canvas's locked
  /// ratio back to the binding when it changes.
  public consuming func lockedAspectRatio(_ ratio: Binding<PixelAspectRatio?>) -> Self {
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
  let rotationInput: Binding<CropEditingState.Rotation?>
  let straightenAngleInput: Binding<Angle?>
  let lockedAspectRatioInput: Binding<PixelAspectRatio?>
  let resetAction: ImageEditorCanvas.ResetAction?
  let rotateAction: ImageEditorCanvas.RotateAction?
  let applyAction: ImageEditorCanvas.ApplyAction?
  let adjustmentAngleCommitAction: ImageEditorCanvas.AdjustmentAngleCommitAction?
  let stateHandler: @MainActor (ImageEditorCanvas.StateSnapshot) -> Void
  let isGuideInteractionEnabled: Bool
  let areAnimationsEnabled: Bool
  let clipsToGuide: Bool
  let contentInset: UIEdgeInsets?
  let editingTarget: ImageEditorCanvas.Target?
  let brush: ImageEditorCanvas.Brush

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeUIView(context: Context) -> EditingCanvasView {
    let view: EditingCanvasView
    if let contentInset {
      view = .init(source: source, feature: feature, contentInset: contentInset)
    } else {
      view = .init(source: source, feature: feature)
    }

    view.isGuideInteractionEnabled = isGuideInteractionEnabled
    view.areAnimationsEnabled = areAnimationsEnabled
    view.clipsToGuide = clipsToGuide
    view.setBrush(brush)
    // The target is set before loading, so loading never runs the "leave
    // crop editing" commit against an unloaded view.
    view.setEditingTarget(editingTarget)
    bindStateHandler(to: view, coordinator: context.coordinator)
    bindFeatureChangeHandler(to: view, coordinator: context.coordinator)

    // `contentInset` above and the two overlays below are creation-only inputs,
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
    bindStateHandler(to: canvasView, coordinator: context.coordinator)
    bindFeatureChangeHandler(to: canvasView, coordinator: context.coordinator)

    if canvasView.isGuideInteractionEnabled != isGuideInteractionEnabled {
      canvasView.isGuideInteractionEnabled = isGuideInteractionEnabled
    }

    if canvasView.areAnimationsEnabled != areAnimationsEnabled {
      canvasView.areAnimationsEnabled = areAnimationsEnabled
    }

    // Everything that pushes SwiftUI inputs into EditingCanvasView runs inside the
    // guard. `setFeature` and `setEditingTarget` can emit a state snapshot
    // or a feature change synchronously, and an unguarded one writes the
    // host's bindings from inside `updateUIView` — a state mutation during
    // view update. The coordinator defers both. `setBrush` cannot emit
    // today; it is inside for a uniform contract, so a future emitting setter
    // is safe by default.
    //
    // Order matters:
    // - The rotation and angle inputs run before `setFeature`. They mirror
    //   the proposed crop through deferred snapshots, so when `setFeature`
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

      if let rotation = rotationInput.wrappedValue {
        canvasView.setRotation(rotation)
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
  private func bindStateHandler(to canvasView: EditingCanvasView, coordinator: Coordinator) {
    coordinator.bindStateHandler(
      to: canvasView,
      syncInputs: { snapshot in
        syncInputs(with: snapshot)
      },
      stateHandler: stateHandler
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

      canvasView.rotateClockwise()
    }

    applyAction?.onCall = { [weak canvasView] in
      canvasView?.applyPendingCrop()
    }

    adjustmentAngleCommitAction?.onCall = { [weak canvasView] angle in
      canvasView?.commitStraightenAngle(angle)
    }
  }

  @MainActor
  private func syncInputs(with snapshot: ImageEditorCanvas.StateSnapshot) {
    if let crop = snapshot.proposedCrop {
      rotationInput.setIfChanged(crop.rotation)
      straightenAngleInput.setIfChanged(crop.adjustmentAngle)
    }
    lockedAspectRatioInput.setIfChanged(snapshot.preferredAspectRatio)
  }

  @MainActor
  final class Coordinator {

    private var isApplyingSwiftUIInputs = false
    private var pendingInputSyncSnapshot: ImageEditorCanvas.StateSnapshot?

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

    func bindStateHandler(
      to canvasView: EditingCanvasView,
      syncInputs: @escaping @MainActor (ImageEditorCanvas.StateSnapshot) -> Void,
      stateHandler: @escaping @MainActor (ImageEditorCanvas.StateSnapshot) -> Void
    ) {
      canvasView.setStateHandler { [weak self] snapshot in
        guard let self else { return }

        self.handleStateSnapshot(
          snapshot,
          syncInputs: syncInputs,
          stateHandler: stateHandler
        )
      }
    }

    func applySwiftUIInputs(_ body: () -> Void) {
      isApplyingSwiftUIInputs = true
      defer {
        isApplyingSwiftUIInputs = false
      }

      body()
    }

    private func handleStateSnapshot(
      _ snapshot: ImageEditorCanvas.StateSnapshot,
      syncInputs: @escaping @MainActor (ImageEditorCanvas.StateSnapshot) -> Void,
      stateHandler: @MainActor (ImageEditorCanvas.StateSnapshot) -> Void
    ) {
      if isApplyingSwiftUIInputs {
        pendingInputSyncSnapshot = snapshot
        schedulePendingInputSync(syncInputs)
      } else {
        syncInputs(snapshot)
      }

      stateHandler(snapshot)
    }

    private func schedulePendingInputSync(
      _ syncInputs: @escaping @MainActor (ImageEditorCanvas.StateSnapshot) -> Void
    ) {
      Task { @MainActor [weak self] in
        guard let self else { return }

        if self.isApplyingSwiftUIInputs {
          self.schedulePendingInputSync(syncInputs)
          return
        }

        guard let snapshot = self.pendingInputSyncSnapshot else {
          return
        }

        self.pendingInputSyncSnapshot = nil
        syncInputs(snapshot)
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
