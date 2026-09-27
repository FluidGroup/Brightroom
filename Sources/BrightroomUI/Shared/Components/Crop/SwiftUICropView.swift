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

@available(iOS 14, *)
public struct SwiftUICropView: View {

  public struct AdjustmentKind: OptionSet, Equatable, Sendable {

    public let rawValue: Int

    public init(rawValue: Int) {
      self.rawValue = rawValue
    }

    public static let scrollView = AdjustmentKind(rawValue: 1 << 0)
    public static let guide = AdjustmentKind(rawValue: 1 << 1)
  }

  public struct StateSnapshot: Equatable {
    public var proposedCrop: CropEditingState?
    public var frame: CGRect
    public var adjustmentKind: AdjustmentKind
    public var preferredAspectRatio: PixelAspectRatio?

    public init(
      proposedCrop: CropEditingState?,
      frame: CGRect,
      adjustmentKind: AdjustmentKind,
      preferredAspectRatio: PixelAspectRatio?
    ) {
      self.proposedCrop = proposedCrop
      self.frame = frame
      self.adjustmentKind = adjustmentKind
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

  /// Commits the current live straighten angle into CropView's recorded crop
  /// geometry.
  ///
  /// Use this from controls that stream `adjustmentAngle` while dragging but
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
    _ change: CropView.DocumentChange,
    preparedFor image: SourceImage,
    to document: Binding<EditingDocument<PhotosCropFeature>>
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
  private let cropInsideOverlay: ((AdjustmentKind?) -> AnyView)?

  /// Fixed at creation. See the initializer documentation.
  private let cropOutsideOverlay: ((AdjustmentKind?) -> AnyView)?

  private let document: Binding<EditingDocument<PhotosCropFeature>>

  /// The stack a built-in editor shares with its other views; nil when the
  /// view prepares the document's image itself.
  private let editingStack: EditingStack?

  private var rotationInput: Binding<CropEditingState.Rotation?> = .constant(nil)
  private var adjustmentAngleInput: Binding<CropEditingState.AdjustmentAngle?> = .constant(nil)
  private var croppingAspectRatioInput: Binding<PixelAspectRatio?> = .constant(nil)
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
  private var editingTarget: CropViewEditingTarget? = .crop
  private var maskingBrush: CropViewMaskingBrush = .init(diameter: .viewportPoints(30))
  private var strokeSmoothing: EditingCanvasStrokeSmoothingConfiguration = .init()

  /// Creates a crop canvas that edits `document`, with custom overlays.
  ///
  /// The view prepares the document's image for display and shows a
  /// progress indicator until it is ready. Changes made on the canvas (crop
  /// commits through `ApplyAction` or when leaving crop editing, and brush
  /// strokes) are applied to the binding's latest document's `feature`; the
  /// view never commits them to the history, so call `commit()` when a change
  /// should become an undo step. A document set from outside (for example an
  /// undo) is displayed, and its crop reloads the crop guide. A document of
  /// another image rebuilds the canvas.
  ///
  /// A host that sets `document.blurMask` with its own blur before the first
  /// stroke pays for that blur at export until a stroke lands. The canvas
  /// previews a blur mask only when its tree is rooted at a brush, which is
  /// the shape the view authors; another root renders at export only.
  ///
  /// - Parameters:
  ///   - document: The edited document.
  ///   - isGuideInteractionEnabled: Applied on every update.
  ///   - areAnimationsEnabled: Applied on every update.
  ///   - contentInset: **Fixed at creation.** `CropView` stores the inset as a
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
    document: Binding<EditingDocument<PhotosCropFeature>>,
    isGuideInteractionEnabled: Bool = true,
    areAnimationsEnabled: Bool = true,
    contentInset: UIEdgeInsets? = nil,
    @ViewBuilder cropInsideOverlay: @escaping (AdjustmentKind?) -> InsideOverlay,
    @ViewBuilder cropOutsideOverlay: @escaping (AdjustmentKind?) -> OutsideOverlay,
    stateHandler: @escaping @MainActor (StateSnapshot) -> Void = { _ in }
  ) {
    self.document = document
    self.editingStack = nil
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
  ///   - contentInset: **Fixed at creation.** `CropView` stores the inset as a
  ///     `let`, so a value supplied after the canvas is mounted is ignored. A
  ///     host that derives the inset from safe area or size class must give
  ///     this view a new identity (for example with `.id`) for a new inset to
  ///     take effect.
  ///   - stateHandler: Re-bound on every update.
  public init(
    document: Binding<EditingDocument<PhotosCropFeature>>,
    isGuideInteractionEnabled: Bool = true,
    areAnimationsEnabled: Bool = true,
    contentInset: UIEdgeInsets? = nil,
    stateHandler: @escaping @MainActor (StateSnapshot) -> Void = { _ in }
  ) {
    self.cropInsideOverlay = nil
    self.cropOutsideOverlay = nil
    self.document = document
    self.editingStack = nil
    self.isGuideInteractionEnabled = isGuideInteractionEnabled
    self.areAnimationsEnabled = areAnimationsEnabled
    self.contentInset = contentInset
    self.stateHandler = stateHandler
  }

  /// Creates a crop canvas with the built-in overlays over a stack a
  /// built-in editor already prepares for `document`'s image.
  init(
    document: Binding<EditingDocument<PhotosCropFeature>>,
    editingStack: EditingStack,
    isGuideInteractionEnabled: Bool
  ) {
    self.cropInsideOverlay = nil
    self.cropOutsideOverlay = nil
    self.document = document
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
        LoadedCropViewRepresentable(
          source: CropViewSource(loadedState),
          document: document.wrappedValue.feature,
          onDocumentChange: { [document] change in
            Self.apply(change, preparedFor: loadedState.image, to: document)
          },
          cropInsideOverlay: cropInsideOverlay,
          cropOutsideOverlay: cropOutsideOverlay,
          rotationInput: rotationInput,
          adjustmentAngleInput: adjustmentAngleInput,
          croppingAspectRatioInput: croppingAspectRatioInput,
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
          maskingBrush: maskingBrush,
          strokeSmoothing: strokeSmoothing
        )
        // `CropView` binds its source once, at creation. Tying the
        // representable's identity to the image makes an image swap rebuild
        // the canvas instead of leaving it bound to the old image.
        .id(loadedState.image)
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

  public consuming func adjustmentAngle(_ angle: CropEditingState.AdjustmentAngle?) -> Self {

    self.adjustmentAngleInput = .constant(angle)
    return self
  }

  public consuming func adjustmentAngle(_ angle: Binding<CropEditingState.AdjustmentAngle?>) -> Self {

    self.adjustmentAngleInput = angle
    return self
  }

  public consuming func registerAdjustmentAngleCommitAction(_ action: AdjustmentAngleCommitAction) -> Self {
    self._adjustmentAngleCommitAction = action
    return self
  }

  public consuming func croppingAspectRatio(_ rect: PixelAspectRatio?) -> Self {

    self.croppingAspectRatioInput = .constant(rect)
    return self

  }

  public consuming func croppingAspectRatio(_ rect: Binding<PixelAspectRatio?>) -> Self {

    self.croppingAspectRatioInput = rect
    return self

  }

  /// Sets which part of the document canvas gestures edit; nil views the
  /// output only. The default is `.crop`.
  ///
  /// Leaving `.crop` commits the visible crop to the document.
  public consuming func editingTarget(_ target: CropViewEditingTarget?) -> Self {
    self.editingTarget = target
    return self
  }

  /// Sets the masking brush. The diameter may be authored in viewport points
  /// or image pixels; CropView resolves it against its own geometry.
  public consuming func maskingBrush(_ brush: CropViewMaskingBrush) -> Self {
    self.maskingBrush = brush
    return self
  }

  public consuming func strokeSmoothing(_ smoothing: EditingCanvasStrokeSmoothingConfiguration) -> Self {
    self.strokeSmoothing = smoothing
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

/// Hosts a `CropView` once the image and the document are available.
///
/// Internal (not private) so tests can drive its coordinator.
@available(iOS 14, *)
struct LoadedCropViewRepresentable: UIViewRepresentable {

  let source: CropViewSource
  let document: PhotosCropFeature
  let onDocumentChange: @MainActor (_ change: CropView.DocumentChange) -> Void
  let cropInsideOverlay: ((SwiftUICropView.AdjustmentKind?) -> AnyView)?
  let cropOutsideOverlay: ((SwiftUICropView.AdjustmentKind?) -> AnyView)?
  let rotationInput: Binding<CropEditingState.Rotation?>
  let adjustmentAngleInput: Binding<CropEditingState.AdjustmentAngle?>
  let croppingAspectRatioInput: Binding<PixelAspectRatio?>
  let resetAction: SwiftUICropView.ResetAction?
  let rotateAction: SwiftUICropView.RotateAction?
  let applyAction: SwiftUICropView.ApplyAction?
  let adjustmentAngleCommitAction: SwiftUICropView.AdjustmentAngleCommitAction?
  let stateHandler: @MainActor (SwiftUICropView.StateSnapshot) -> Void
  let isGuideInteractionEnabled: Bool
  let areAnimationsEnabled: Bool
  let clipsToGuide: Bool
  let contentInset: UIEdgeInsets?
  let editingTarget: CropViewEditingTarget?
  let maskingBrush: CropViewMaskingBrush
  let strokeSmoothing: EditingCanvasStrokeSmoothingConfiguration

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeUIView(context: Context) -> CropView {
    let view: CropView
    if let contentInset {
      view = .init(source: source, document: document, contentInset: contentInset)
    } else {
      view = .init(source: source, document: document)
    }

    view.isGuideInteractionEnabled = isGuideInteractionEnabled
    view.areAnimationsEnabled = areAnimationsEnabled
    view.clipsToGuide = clipsToGuide
    view.setMaskingBrush(maskingBrush)
    view.setCanvasStrokeSmoothing(strokeSmoothing)
    // The target is set before loading, so loading never runs the "leave
    // crop editing" commit against an unloaded view.
    view.setEditingTarget(editingTarget)
    bindStateHandler(to: view, coordinator: context.coordinator)
    bindDocumentChangeHandler(to: view, coordinator: context.coordinator)

    // `contentInset` above and the two overlays below are creation-only inputs,
    // as documented on SwiftUICropView's initializers. `updateUIView`
    // deliberately does not re-apply them: `contentInset` is a `let` on
    // CropView, and re-installing `AnyView` overlay closures on every update
    // would rebuild the hosted overlays for no gain. Wiring live overlays would
    // need an explicit change token, not an unconditional re-set.
    if let cropInsideOverlay {
      view.setCropInsideOverlay(CropView.SwiftUICropInsideOverlay(content: cropInsideOverlay))
    }

    if let cropOutsideOverlay {
      view.setCropOutsideOverlay(CropView.SwiftUICropOutsideOverlay(content: cropOutsideOverlay))
    }

    configureActions(on: view)
    context.coordinator.applySwiftUIInputs {
      view.loadDocumentState()
    }

    return view
  }

  func updateUIView(_ cropView: CropView, context: Context) {
    bindStateHandler(to: cropView, coordinator: context.coordinator)
    bindDocumentChangeHandler(to: cropView, coordinator: context.coordinator)

    if cropView.isGuideInteractionEnabled != isGuideInteractionEnabled {
      cropView.isGuideInteractionEnabled = isGuideInteractionEnabled
    }

    if cropView.areAnimationsEnabled != areAnimationsEnabled {
      cropView.areAnimationsEnabled = areAnimationsEnabled
    }

    // Everything that pushes SwiftUI inputs into CropView runs inside the
    // guard. `setDocument` and `setEditingTarget` can emit a state snapshot
    // or a document change synchronously, and an unguarded one writes the
    // host's bindings from inside `updateUIView` — a state mutation during
    // view update. The coordinator defers both. `setMaskingBrush` and
    // `setCanvasStrokeSmoothing` cannot emit today; they are inside for a
    // uniform contract, so a future emitting setter is safe by default.
    //
    // Order matters:
    // - The rotation and angle inputs run before `setDocument`. They mirror
    //   the proposed crop through deferred snapshots, so when `setDocument`
    //   reloads the crop (an undo), they still hold the previous values and
    //   would otherwise rotate the reloaded crop back.
    // - `setDocument` runs before `setEditingTarget`. When an undo and a
    //   switch away from `.crop` arrive together, the crop reloads first, and
    //   leaving `.crop` then commits nothing over the host's undo.
    // - While document changes are queued, the owner still holds the
    //   document from before them, so they are applied to it for display.
    context.coordinator.applySwiftUIInputs {
      if cropView.clipsToGuide != clipsToGuide {
        cropView.clipsToGuide = clipsToGuide
      }

      if let rotation = rotationInput.wrappedValue {
        cropView.setRotation(rotation)
      }

      if let adjustmentAngle = adjustmentAngleInput.wrappedValue {
        cropView.setAdjustmentAngle(
          adjustmentAngle,
          recordsCropExtent: adjustmentAngleCommitAction == nil
        )
      }

      cropView.setCroppingAspectRatio(croppingAspectRatioInput.wrappedValue)

      cropView.setMaskingBrush(maskingBrush)
      cropView.setCanvasStrokeSmoothing(strokeSmoothing)

      // Also refreshes the display for the inputs above.
      cropView.setDocument(context.coordinator.applyingPendingDocumentChanges(to: document))
      cropView.setEditingTarget(editingTarget)
    }

    configureActions(on: cropView)
  }

  @MainActor
  private func bindStateHandler(to cropView: CropView, coordinator: Coordinator) {
    coordinator.bindStateHandler(
      to: cropView,
      syncInputs: { snapshot in
        syncInputs(with: snapshot)
      },
      stateHandler: stateHandler
    )
  }

  @MainActor
  private func bindDocumentChangeHandler(to cropView: CropView, coordinator: Coordinator) {
    coordinator.bindDocumentChangeHandler(
      to: cropView,
      onDocumentChange: onDocumentChange
    )
  }

  @MainActor
  private func configureActions(on cropView: CropView) {
    resetAction?.onCall = { [weak cropView] in
      guard let cropView else { return }

      cropView.resetCrop()
    }

    rotateAction?.onCall = { [weak cropView] in
      guard let cropView else { return }

      cropView.rotateClockwise()
    }

    applyAction?.onCall = { [weak cropView] in
      cropView?.applyDocumentChanges()
    }

    adjustmentAngleCommitAction?.onCall = { [weak cropView] angle in
      cropView?.commitAdjustmentAngle(angle)
    }
  }

  @MainActor
  private func syncInputs(with snapshot: SwiftUICropView.StateSnapshot) {
    if let crop = snapshot.proposedCrop {
      rotationInput.setIfChanged(crop.rotation)
      adjustmentAngleInput.setIfChanged(crop.adjustmentAngle)
    }
    croppingAspectRatioInput.setIfChanged(snapshot.preferredAspectRatio)
  }

  @MainActor
  final class Coordinator {

    private var isApplyingSwiftUIInputs = false
    private var pendingInputSyncSnapshot: SwiftUICropView.StateSnapshot?

    /// Document changes emitted while SwiftUI inputs were being applied, not
    /// yet applied by the owner, in emission order.
    ///
    /// Until they are delivered, the owner still holds the document from
    /// before them; `updateUIView` displays them applied to it so CropView
    /// does not reload the stale crop.
    private var pendingDocumentChanges: [CropView.DocumentChange] = []

    private var onDocumentChange: @MainActor (_ change: CropView.DocumentChange) -> Void = { _ in }

    /// Routes CropView's document changes to `onDocumentChange`, re-bound on
    /// every update because the host's destination can change.
    func bindDocumentChangeHandler(
      to cropView: CropView,
      onDocumentChange: @escaping @MainActor (_ change: CropView.DocumentChange) -> Void
    ) {
      self.onDocumentChange = onDocumentChange
      cropView.setDocumentChangeHandler { [weak self] change in
        self?.deliverDocumentChange(change)
      }
    }

    /// Applies a change to the owner's document: now, or on the next
    /// main-actor turn when it was emitted while SwiftUI inputs were being
    /// applied. Changes are delivered in emission order.
    func deliverDocumentChange(_ change: @escaping CropView.DocumentChange) {
      if isApplyingSwiftUIInputs {
        if pendingDocumentChanges.isEmpty {
          schedulePendingDocumentDelivery()
        }
        pendingDocumentChanges.append(change)
      } else {
        deliverPendingDocumentChanges()
        onDocumentChange(change)
      }
    }

    /// `document` with the undelivered changes applied.
    func applyingPendingDocumentChanges(to document: PhotosCropFeature) -> PhotosCropFeature {
      var document = document
      for change in pendingDocumentChanges {
        change(&document)
      }
      return document
    }

    private func deliverPendingDocumentChanges() {
      let changes = pendingDocumentChanges
      pendingDocumentChanges = []
      for change in changes {
        onDocumentChange(change)
      }
    }

    private func schedulePendingDocumentDelivery() {
      Task { @MainActor [weak self] in
        guard let self else { return }

        if self.isApplyingSwiftUIInputs {
          self.schedulePendingDocumentDelivery()
          return
        }

        self.deliverPendingDocumentChanges()
      }
    }

    func bindStateHandler(
      to cropView: CropView,
      syncInputs: @escaping @MainActor (SwiftUICropView.StateSnapshot) -> Void,
      stateHandler: @escaping @MainActor (SwiftUICropView.StateSnapshot) -> Void
    ) {
      cropView.setStateHandler { [weak self] snapshot in
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
      _ snapshot: SwiftUICropView.StateSnapshot,
      syncInputs: @escaping @MainActor (SwiftUICropView.StateSnapshot) -> Void,
      stateHandler: @MainActor (SwiftUICropView.StateSnapshot) -> Void
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
      _ syncInputs: @escaping @MainActor (SwiftUICropView.StateSnapshot) -> Void
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
