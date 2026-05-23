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
import StateGraph
import BrightroomEngine

public final class _PixelEditor_WrapperViewController<BodyView: UIView>: UIViewController {
  
  let bodyView: BodyView
  
  init(bodyView: BodyView) {
    self.bodyView = bodyView
    super.init(nibName: nil, bundle: nil)
  }
  
  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  public override func viewDidLoad() {
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
    public var proposedCrop: EditingCrop?
    public var frame: CGRect
    public var adjustmentKind: AdjustmentKind
    public var preferredAspectRatio: PixelAspectRatio?

    public init(
      proposedCrop: EditingCrop?,
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

  private let cropInsideOverlay: ((AdjustmentKind?) -> AnyView)?
  private let cropOutsideOverlay: ((AdjustmentKind?) -> AnyView)?

  private let editingStack: EditingStack

  private var rotationInput: Binding<EditingCrop.Rotation?> = .constant(nil)
  private var adjustmentAngleInput: Binding<EditingCrop.AdjustmentAngle?> = .constant(nil)
  private var croppingAspectRatioInput: Binding<PixelAspectRatio?> = .constant(nil)
  private var _resetAction: ResetAction?
  private var _rotateAction: RotateAction?
  private var _applyAction: ApplyAction?

  private let stateHandler: @MainActor (StateSnapshot) -> Void
  private let isGuideInteractionEnabled: Bool
  private let isAutoApplyEditingStackEnabled: Bool
  private let areAnimationsEnabled: Bool
  private let contentInset: UIEdgeInsets?

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
      if let loadedState = editingStack.loadedState {
        LoadedCropViewRepresentable(
          editingStack: editingStack,
          loadedState: loadedState,
          cropInsideOverlay: cropInsideOverlay,
          cropOutsideOverlay: cropOutsideOverlay,
          rotationInput: rotationInput,
          adjustmentAngleInput: adjustmentAngleInput,
          croppingAspectRatioInput: croppingAspectRatioInput,
          resetAction: _resetAction,
          rotateAction: _rotateAction,
          applyAction: _applyAction,
          stateHandler: stateHandler,
          isGuideInteractionEnabled: isGuideInteractionEnabled,
          isAutoApplyEditingStackEnabled: isAutoApplyEditingStackEnabled,
          areAnimationsEnabled: areAnimationsEnabled,
          contentInset: contentInset
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

  public consuming func rotation(_ rotation: EditingCrop.Rotation?) -> Self {
    self.rotationInput = .constant(rotation)
    return self
  }

  public consuming func rotation(_ rotation: Binding<EditingCrop.Rotation?>) -> Self {

    self.rotationInput = rotation
    return self
  }

  public consuming func adjustmentAngle(_ angle: EditingCrop.AdjustmentAngle?) -> Self {

    self.adjustmentAngleInput = .constant(angle)
    return self
  }

  public consuming func adjustmentAngle(_ angle: Binding<EditingCrop.AdjustmentAngle?>) -> Self {

    self.adjustmentAngleInput = angle
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
  let loadedState: EditingStack.Loaded
  let cropInsideOverlay: ((SwiftUICropView.AdjustmentKind?) -> AnyView)?
  let cropOutsideOverlay: ((SwiftUICropView.AdjustmentKind?) -> AnyView)?
  let rotationInput: Binding<EditingCrop.Rotation?>
  let adjustmentAngleInput: Binding<EditingCrop.AdjustmentAngle?>
  let croppingAspectRatioInput: Binding<PixelAspectRatio?>
  let resetAction: SwiftUICropView.ResetAction?
  let rotateAction: SwiftUICropView.RotateAction?
  let applyAction: SwiftUICropView.ApplyAction?
  let stateHandler: @MainActor (SwiftUICropView.StateSnapshot) -> Void
  let isGuideInteractionEnabled: Bool
  let isAutoApplyEditingStackEnabled: Bool
  let areAnimationsEnabled: Bool
  let contentInset: UIEdgeInsets?

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
    view.setStateHandler { snapshot in
      syncInputs(with: snapshot)
      stateHandler(snapshot)
    }

    if let cropInsideOverlay {
      view.setCropInsideOverlay(CropView.SwiftUICropInsideOverlay(content: cropInsideOverlay))
    }

    if let cropOutsideOverlay {
      view.setCropOutsideOverlay(CropView.SwiftUICropOutsideOverlay(content: cropOutsideOverlay))
    }

    configureActions(on: view)
    view.load(image: loadedState.imageForCrop, crop: loadedState.currentEdit.crop)

    return .init(bodyView: view)
  }

  func updateUIViewController(_ uiViewController: _PixelEditor_WrapperViewController<CropView>, context: Context) {
    let cropView = uiViewController.bodyView
    cropView.setStateHandler { snapshot in
      syncInputs(with: snapshot)
      stateHandler(snapshot)
    }

    if cropView.isGuideInteractionEnabled != isGuideInteractionEnabled {
      cropView.isGuideInteractionEnabled = isGuideInteractionEnabled
    }

    if cropView.isAutoApplyEditingStackEnabled != isAutoApplyEditingStackEnabled {
      cropView.isAutoApplyEditingStackEnabled = isAutoApplyEditingStackEnabled
    }

    if cropView.areAnimationsEnabled != areAnimationsEnabled {
      cropView.areAnimationsEnabled = areAnimationsEnabled
    }

    if let rotation = rotationInput.wrappedValue {
      cropView.setRotation(rotation)
    }

    if let adjustmentAngle = adjustmentAngleInput.wrappedValue {
      cropView.setAdjustmentAngle(adjustmentAngle)
    }

    cropView.setCroppingAspectRatio(croppingAspectRatioInput.wrappedValue)

    configureActions(on: cropView)
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
  }

  @MainActor
  private func syncInputs(with snapshot: SwiftUICropView.StateSnapshot) {
    if let crop = snapshot.proposedCrop {
      rotationInput.setIfChanged(crop.rotation)
      adjustmentAngleInput.setIfChanged(crop.adjustmentAngle)
    }
    croppingAspectRatioInput.setIfChanged(snapshot.preferredAspectRatio)
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
