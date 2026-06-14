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

final class _PixelEditor_WrapperViewController<BodyView: UIView>: UIViewController {
  
  let bodyView: BodyView
  
  init(bodyView: BodyView) {
    self.bodyView = bodyView
    super.init(nibName: nil, bundle: nil)
  }
  
  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  override func viewDidLoad() {
    super.viewDidLoad()
    
    view.addSubview(bodyView)
    AutoLayoutTools.setEdge(bodyView, view)
  }
}

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

  private let cropInsideOverlay: ((AdjustmentKind?) -> AnyView)?
  private let cropOutsideOverlay: ((AdjustmentKind?) -> AnyView)?

  private let editingStack: EditingStack

  private var rotationInput: Binding<CropEditingState.Rotation?> = .constant(nil)
  private var adjustmentAngleInput: Binding<CropEditingState.AdjustmentAngle?> = .constant(nil)
  private var croppingAspectRatioInput: Binding<PixelAspectRatio?> = .constant(nil)
  private var _resetAction: ResetAction?
  private var _rotateAction: RotateAction?
  private var _applyAction: ApplyAction?
  private var _adjustmentAngleCommitAction: AdjustmentAngleCommitAction?

  private let stateHandler: @MainActor (StateSnapshot) -> Void
  private let isGuideInteractionEnabled: Bool
  private let isAutoApplyEditingStackEnabled: Bool
  private let areAnimationsEnabled: Bool
  private let contentInset: UIEdgeInsets?
  private var featureFocus: CropViewFeatureFocus = .finalCrop
  private var maskingBrush: CropViewMaskingBrush = .init(diameter: .viewportPoints(30))
  private var strokeSmoothing: EditingCanvasStrokeSmoothingConfiguration = .init()

  public init<InsideOverlay: View, OutsideOverlay: View>(
    editingStack: EditingStack,
    isGuideInteractionEnabled: Bool = true,
    isAutoApplyEditingStackEnabled: Bool = false,
    areAnimationsEnabled: Bool = true,
    contentInset: UIEdgeInsets? = nil,
    @ViewBuilder cropInsideOverlay: @escaping (AdjustmentKind?) -> InsideOverlay,
    @ViewBuilder cropOutsideOverlay: @escaping (AdjustmentKind?) -> OutsideOverlay,
    stateHandler: @escaping @MainActor (StateSnapshot) -> Void = { _ in }
  ) {
    self.editingStack = editingStack
    self.isGuideInteractionEnabled = isGuideInteractionEnabled
    self.isAutoApplyEditingStackEnabled = isAutoApplyEditingStackEnabled
    self.areAnimationsEnabled = areAnimationsEnabled
    self.contentInset = contentInset
    self.cropInsideOverlay = { AnyView(cropInsideOverlay($0)) }
    self.cropOutsideOverlay = { AnyView(cropOutsideOverlay($0)) }
    self.stateHandler = stateHandler
  }

  public init(
    editingStack: EditingStack,
    isGuideInteractionEnabled: Bool = true,
    isAutoApplyEditingStackEnabled: Bool = false,
    areAnimationsEnabled: Bool = true,
    contentInset: UIEdgeInsets? = nil,
    stateHandler: @escaping @MainActor (StateSnapshot) -> Void = { _ in }
  ) {
    self.cropInsideOverlay = nil
    self.cropOutsideOverlay = nil
    self.editingStack = editingStack
    self.isGuideInteractionEnabled = isGuideInteractionEnabled
    self.isAutoApplyEditingStackEnabled = isAutoApplyEditingStackEnabled
    self.areAnimationsEnabled = areAnimationsEnabled
    self.contentInset = contentInset
    self.stateHandler = stateHandler
  }

  public var body: some View {
    ZStack {
      if editingStack.loadedState != nil {
        LoadedCropViewRepresentable(
          editingStack: editingStack,
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
          isAutoApplyEditingStackEnabled: isAutoApplyEditingStackEnabled,
          areAnimationsEnabled: areAnimationsEnabled,
          contentInset: contentInset,
          featureFocus: featureFocus,
          maskingBrush: maskingBrush,
          strokeSmoothing: strokeSmoothing
        )
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
private struct LoadedCropViewRepresentable: UIViewControllerRepresentable {

  typealias UIViewControllerType = _PixelEditor_WrapperViewController<CropView>

  let editingStack: EditingStack
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
  let isAutoApplyEditingStackEnabled: Bool
  let areAnimationsEnabled: Bool
  let contentInset: UIEdgeInsets?
  let featureFocus: CropViewFeatureFocus
  let maskingBrush: CropViewMaskingBrush
  let strokeSmoothing: EditingCanvasStrokeSmoothingConfiguration

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeUIViewController(context: Context) -> _PixelEditor_WrapperViewController<CropView> {
    let view: CropView
    if let contentInset {
      view = .init(editingStack: editingStack, contentInset: contentInset)
    } else {
      view = .init(editingStack: editingStack)
    }

    view.isAutoApplyEditingStackEnabled = isAutoApplyEditingStackEnabled
    view.isGuideInteractionEnabled = isGuideInteractionEnabled
    view.areAnimationsEnabled = areAnimationsEnabled
    view.setMaskingBrush(maskingBrush)
    view.setCanvasStrokeSmoothing(strokeSmoothing)
    view.setFeatureFocus(featureFocus)
    bindStateHandler(to: view, coordinator: context.coordinator)

    if let cropInsideOverlay {
      view.setCropInsideOverlay(CropView.SwiftUICropInsideOverlay(content: cropInsideOverlay))
    }

    if let cropOutsideOverlay {
      view.setCropOutsideOverlay(CropView.SwiftUICropOutsideOverlay(content: cropOutsideOverlay))
    }

    configureActions(on: view)
    context.coordinator.applySwiftUIInputs {
      view.loadCurrentEditingStackState()
    }

    return .init(bodyView: view)
  }

  func updateUIViewController(_ uiViewController: _PixelEditor_WrapperViewController<CropView>, context: Context) {
    let cropView = uiViewController.bodyView
    bindStateHandler(to: cropView, coordinator: context.coordinator)

    if cropView.isGuideInteractionEnabled != isGuideInteractionEnabled {
      cropView.isGuideInteractionEnabled = isGuideInteractionEnabled
    }

    if cropView.isAutoApplyEditingStackEnabled != isAutoApplyEditingStackEnabled {
      cropView.isAutoApplyEditingStackEnabled = isAutoApplyEditingStackEnabled
    }

    if cropView.areAnimationsEnabled != areAnimationsEnabled {
      cropView.areAnimationsEnabled = areAnimationsEnabled
    }

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
    }

    cropView.setMaskingBrush(maskingBrush)
    cropView.setCanvasStrokeSmoothing(strokeSmoothing)
    cropView.setFeatureFocus(featureFocus)

    cropView.updateCurrentEditingStackDisplay()
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
      cropView?.applyEditingStack()
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
