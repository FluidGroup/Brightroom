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
import Verge
#if !COCOAPODS
import BrightroomEngine
#endif

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

/**
 Still in development
 */
@available(iOS 14, *)
public struct SwiftUICropView: UIViewControllerRepresentable {

  public final class ResetAction {

    var onCall: () -> Void = {}

    public init() {

    }

    public func callAsFunction() {
      onCall()
    }
  }

  public typealias UIViewControllerType = _PixelEditor_WrapperViewController<CropView>
      
  private let cropInsideOverlay: ((CropView.State.AdjustmentKind?) -> AnyView)?
  private let cropOutsideOverlay: ((CropView.State.AdjustmentKind?) -> AnyView)?

  private let editingStack: EditingStack

  private var _rotation: EditingCrop.Rotation?
  private var _adjustmentAngle: EditingCrop.AdjustmentAngle?
  private var _croppingAspectRatio: PixelAspectRatio?
  private var _resetAction: ResetAction?

  private let stateHandler: @MainActor (Verge.Changes<CropView.State>) -> Void
  private let isGuideInteractionEnabled: Bool
  private let isAutoApplyEditingStackEnabled: Bool
  private let contentInset: UIEdgeInsets?

  public init<InsideOverlay: View, OutsideOverlay: View>(
    editingStack: EditingStack,
    isGuideInteractionEnabled: Bool = true,
    isAutoApplyEditingStackEnabled: Bool = false,
    contentInset: UIEdgeInsets? = nil,
    @ViewBuilder cropInsideOverlay: @escaping (CropView.State.AdjustmentKind?) -> InsideOverlay,
    @ViewBuilder cropOutsideOverlay: @escaping (CropView.State.AdjustmentKind?) -> OutsideOverlay,
    stateHandler: @escaping @MainActor (Verge.Changes<CropView.State>) -> Void = { _ in }
  ) {
    self.editingStack = editingStack
    self.isGuideInteractionEnabled = isGuideInteractionEnabled
    self.isAutoApplyEditingStackEnabled = isAutoApplyEditingStackEnabled
    self.contentInset = contentInset
    self.cropInsideOverlay = { AnyView(cropInsideOverlay($0)) }
    self.cropOutsideOverlay = { AnyView(cropOutsideOverlay($0)) }
    self.stateHandler = stateHandler
  }

  public init(
    editingStack: EditingStack,
    isGuideInteractionEnabled: Bool = true,
    isAutoApplyEditingStackEnabled: Bool = false,
    contentInset: UIEdgeInsets? = nil,
    stateHandler: @escaping @MainActor (Verge.Changes<CropView.State>) -> Void = { _ in }
  ) {
    self.cropInsideOverlay = nil
    self.cropOutsideOverlay = nil
    self.editingStack = editingStack
    self.isGuideInteractionEnabled = isGuideInteractionEnabled
    self.isAutoApplyEditingStackEnabled = isAutoApplyEditingStackEnabled
    self.contentInset = contentInset
    self.stateHandler = stateHandler
  }

  public func makeUIViewController(context: Context) -> _PixelEditor_WrapperViewController<CropView> {

    let view: CropView
    if let contentInset {
      view = .init(editingStack: editingStack, contentInset: contentInset)
    } else {
      view = .init(editingStack: editingStack)
    }

    view.isAutoApplyEditingStackEnabled = isAutoApplyEditingStackEnabled
    view.isGuideInteractionEnabled = isGuideInteractionEnabled

    if let cropInsideOverlay {
      view.setCropInsideOverlay(CropView.SwiftUICropInsideOverlay(content: cropInsideOverlay))
    }

    if let cropOutsideOverlay {
      view.setCropOutsideOverlay(CropView.SwiftUICropOutsideOverlay(content: cropOutsideOverlay))
    }

    let controller = _PixelEditor_WrapperViewController.init(bodyView: view)

    return controller
  }
  
  public func updateUIViewController(_ uiViewController: _PixelEditor_WrapperViewController<CropView>, context: Context) {

    if let _rotation {
      uiViewController.bodyView.setRotation(_rotation)
    }

    if let _adjustmentAngle {
      uiViewController.bodyView.setAdjustmentAngle(_adjustmentAngle)
    }

    uiViewController.bodyView.setStateHandler(stateHandler)
    uiViewController.bodyView.setCroppingAspectRatio(_croppingAspectRatio)

    _resetAction?.onCall = {
      uiViewController.bodyView.resetCrop()
    }
  }

  public func rotation(_ rotation: EditingCrop.Rotation?) -> Self {

    var modified = self
    modified._rotation = rotation
    return modified
  }

  public func adjustmentAngle(_ angle: EditingCrop.AdjustmentAngle?) -> Self {

    var modified = self
    modified._adjustmentAngle = angle
    return modified

  }

  public func croppingAspectRatio(_ rect: PixelAspectRatio?) -> Self {

    var modified = self
    modified._croppingAspectRatio = rect
    return modified

  }

  public func registerResetAction(_ action: ResetAction) -> Self {

    var modified = self
    modified._resetAction = action
    return modified

  }

}
