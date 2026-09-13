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

  /// Where this view's `CropViewDocument` comes from.
  private enum DocumentSource {

    /// The document is created for — and cached against — this stack.
    case editingStack(EditingStack)

    /// The host owns the document and keeps it stable itself.
    case document(CropViewDocument)
  }

  /// Keeps the view-owned `CropViewDocument` stable across body evaluations.
  ///
  /// `SwiftUICropView` is a struct, so a document built in `init` is rebuilt on
  /// every body evaluation of the host — including the stroke-commit session it
  /// owns — while the mounted `CropView` keeps the instance it was created
  /// with. Holding the document in a `@State` box, which SwiftUI keeps for the
  /// view's lifetime, gives the public `init(editingStack:)` paths the same
  /// stable document PhotosCrop already gets from its editing model.
  ///
  /// Populating the box does not invalidate the view, so doing it from `body`
  /// is not a state write during view update.
  private final class DocumentStore {

    private var editingStack: EditingStack?
    private var document: CropViewDocument?

    @MainActor
    func document(for editingStack: EditingStack) -> CropViewDocument {
      if let document, self.editingStack === editingStack {
        return document
      }

      let document = CropViewDocument(editingStack: editingStack)
      self.editingStack = editingStack
      self.document = document
      return document
    }
  }

  /// Fixed at creation. See the initializer documentation.
  private let cropInsideOverlay: ((AdjustmentKind?) -> AnyView)?

  /// Fixed at creation. See the initializer documentation.
  private let cropOutsideOverlay: ((AdjustmentKind?) -> AnyView)?

  private let documentSource: DocumentSource

  @State private var documentStore = DocumentStore()

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
  /// Fixed at creation. See the initializer documentation.
  private let contentInset: UIEdgeInsets?
  private var featureFocus: CropViewFeatureFocus = .finalCrop
  private var maskingBrush: CropViewMaskingBrush = .init(diameter: .viewportPoints(30))
  private var strokeSmoothing: EditingCanvasStrokeSmoothingConfiguration = .init()

  /// Creates a crop canvas over `editingStack` with custom overlays.
  ///
  /// - Parameters:
  ///   - editingStack: The stack whose current edit is displayed and edited.
  ///     The crop-canvas document created for it is kept for the lifetime of
  ///     this view; passing a different stack rebuilds the canvas.
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
    editingStack: EditingStack,
    isGuideInteractionEnabled: Bool = true,
    areAnimationsEnabled: Bool = true,
    contentInset: UIEdgeInsets? = nil,
    @ViewBuilder cropInsideOverlay: @escaping (AdjustmentKind?) -> InsideOverlay,
    @ViewBuilder cropOutsideOverlay: @escaping (AdjustmentKind?) -> OutsideOverlay,
    stateHandler: @escaping @MainActor (StateSnapshot) -> Void = { _ in }
  ) {
    self.documentSource = .editingStack(editingStack)
    self.isGuideInteractionEnabled = isGuideInteractionEnabled
    self.areAnimationsEnabled = areAnimationsEnabled
    self.contentInset = contentInset
    self.cropInsideOverlay = { AnyView(cropInsideOverlay($0)) }
    self.cropOutsideOverlay = { AnyView(cropOutsideOverlay($0)) }
    self.stateHandler = stateHandler
  }

  /// Creates a crop canvas over `editingStack` with the built-in overlays.
  ///
  /// - Parameters:
  ///   - editingStack: The stack whose current edit is displayed and edited.
  ///     The crop-canvas document created for it is kept for the lifetime of
  ///     this view; passing a different stack rebuilds the canvas.
  ///   - isGuideInteractionEnabled: Applied on every update.
  ///   - areAnimationsEnabled: Applied on every update.
  ///   - contentInset: **Fixed at creation.** `CropView` stores the inset as a
  ///     `let`, so a value supplied after the canvas is mounted is ignored. A
  ///     host that derives the inset from safe area or size class must give
  ///     this view a new identity (for example with `.id`) for a new inset to
  ///     take effect.
  ///   - stateHandler: Re-bound on every update.
  public init(
    editingStack: EditingStack,
    isGuideInteractionEnabled: Bool = true,
    areAnimationsEnabled: Bool = true,
    contentInset: UIEdgeInsets? = nil,
    stateHandler: @escaping @MainActor (StateSnapshot) -> Void = { _ in }
  ) {
    self.cropInsideOverlay = nil
    self.cropOutsideOverlay = nil
    self.documentSource = .editingStack(editingStack)
    self.isGuideInteractionEnabled = isGuideInteractionEnabled
    self.areAnimationsEnabled = areAnimationsEnabled
    self.contentInset = contentInset
    self.stateHandler = stateHandler
  }

  /// Creates a crop canvas over a document the host already owns.
  ///
  /// The caller is responsible for keeping `document` stable across body
  /// evaluations; see `PhotosCropEditingModel.cropViewDocument`.
  ///
  /// `contentInset` is fixed at creation, as in the public initializers.
  init(
    document: CropViewDocument,
    isGuideInteractionEnabled: Bool = true,
    areAnimationsEnabled: Bool = true,
    contentInset: UIEdgeInsets? = nil,
    stateHandler: @escaping @MainActor (StateSnapshot) -> Void = { _ in }
  ) {
    self.cropInsideOverlay = nil
    self.cropOutsideOverlay = nil
    self.documentSource = .document(document)
    self.isGuideInteractionEnabled = isGuideInteractionEnabled
    self.areAnimationsEnabled = areAnimationsEnabled
    self.contentInset = contentInset
    self.stateHandler = stateHandler
  }

  /// The document backing this view, stable for as long as the view keeps its
  /// SwiftUI identity and its `EditingStack`.
  @MainActor
  private var document: CropViewDocument {
    switch documentSource {
    case .editingStack(let editingStack):
      return documentStore.document(for: editingStack)
    case .document(let document):
      return document
    }
  }

  public var body: some View {
    let document = self.document

    ZStack {
      if document.snapshot != nil {
        LoadedCropViewRepresentable(
          document: document,
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
          contentInset: contentInset,
          featureFocus: featureFocus,
          maskingBrush: maskingBrush,
          strokeSmoothing: strokeSmoothing
        )
        // `CropView` binds its document once, at creation. Tying the
        // representable's identity to the document makes a document swap
        // rebuild the canvas instead of leaving it bound to the old one.
        .id(ObjectIdentifier(document))
        .transition(.opacity.animation(.smooth))
      } else {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .transition(.opacity.animation(.smooth))
      }
    }
    .onAppear {
      document.start()
    }
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

  /// Sets which FeatureTree point is previewed and which feature node canvas
  /// gestures edit.
  public consuming func featureFocus(_ focus: CropViewFeatureFocus) -> Self {
    self.featureFocus = focus
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

@available(iOS 14, *)
private struct LoadedCropViewRepresentable: UIViewRepresentable {

  let document: CropViewDocument
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
  let contentInset: UIEdgeInsets?
  let featureFocus: CropViewFeatureFocus
  let maskingBrush: CropViewMaskingBrush
  let strokeSmoothing: EditingCanvasStrokeSmoothingConfiguration

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeUIView(context: Context) -> CropView {
    let view: CropView
    if let contentInset {
      view = .init(document: document, contentInset: contentInset)
    } else {
      view = .init(document: document)
    }

    view.isGuideInteractionEnabled = isGuideInteractionEnabled
    view.areAnimationsEnabled = areAnimationsEnabled
    view.setMaskingBrush(maskingBrush)
    view.setCanvasStrokeSmoothing(strokeSmoothing)
    view.setFeatureFocus(featureFocus)
    bindStateHandler(to: view, coordinator: context.coordinator)

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
      view.loadCurrentDocumentState()
    }

    return view
  }

  func updateUIView(_ cropView: CropView, context: Context) {
    bindStateHandler(to: cropView, coordinator: context.coordinator)

    if cropView.isGuideInteractionEnabled != isGuideInteractionEnabled {
      cropView.isGuideInteractionEnabled = isGuideInteractionEnabled
    }

    if cropView.areAnimationsEnabled != areAnimationsEnabled {
      cropView.areAnimationsEnabled = areAnimationsEnabled
    }

    // Everything that pushes SwiftUI inputs into CropView runs inside the
    // guard. `setFeatureFocus` and `updateCurrentDocumentDisplay` can emit a
    // state snapshot synchronously, and an unguarded snapshot writes the
    // rotation/angle/aspect bindings from inside `updateUIView` — a state
    // mutation during view update. `setMaskingBrush` and
    // `setCanvasStrokeSmoothing` cannot emit today; they are inside for a
    // uniform contract, so a future emitting setter is safe by default.
    context.coordinator.applySwiftUIInputs {
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
      cropView.setFeatureFocus(featureFocus)

      cropView.updateCurrentDocumentDisplay()
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
