//
// Copyright (c) 2018 Muukii <muukii.app@gmail.com>
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

import Photos
import PixelEngine
import UIKit
import Verge

public protocol PixelEditViewControllerDelegate: class {
  func pixelEditViewController(
    _ controller: PixelEditViewController,
    didEndEditing editingStack: EditingStack
  )
  func pixelEditViewControllerDidCancelEditing(in controller: PixelEditViewController)
}

public final class PixelEditViewController: UIViewController {
  public final class Callbacks {
    public var didEndEditing: (PixelEditViewController, EditingStack) -> Void = { _, _ in }
    public var didCancelEditing: (PixelEditViewController) -> Void = { _ in }
  }

  public weak var delegate: PixelEditViewControllerDelegate?

  public let callbacks: Callbacks = .init()

  // MARK: - Private Propaties

  private let maskingView = BlurredMosaicView()

  private let previewView: ImagePreviewView
  
  private let cropView: CropView

  private let editContainerView = UIView()

  private let controlContainerView = UIView()

  private let cropButton = UIButton(type: .system)

  private let stackView = ControlStackView()

  private var aspectConstraint: NSLayoutConstraint?

  private lazy var doneButton = UIBarButtonItem(
    title: viewModel.doneButtonTitle,
    style: .done,
    target: self,
    action: #selector(didTapDoneButton)
  )

  private lazy var cancelButton = UIBarButtonItem(
    title: L10n.cancel,
    style: .plain,
    target: self,
    action: #selector(didTapCancelButton)
  )

  private var subscriptions: Set<VergeAnyCancellable> = .init()

  private lazy var loadingView = LoadingView()
  private lazy var touchGuardOverlayView = UIView()

  private let viewModel: PixelEditViewModel
  
  // MARK: - Initializers

  public init(viewModel: PixelEditViewModel) {
    self.viewModel = viewModel
    self.cropView = .init(editingStack: viewModel.editingStack, contentInset: .zero)
    self.previewView = .init(editingStack: viewModel.editingStack)
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  public required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Functions

  override public func viewDidLoad() {
    super.viewDidLoad()
    
    cropView.setCropOutsideOverlay(nil)
    cropView.setCropInsideOverlay(nil)
    cropView.isGuideInteractionEnabled = false
    cropView.setCroppingAspectRatio(.square)

    layout: do {
      root: do {
        view.backgroundColor = .white

        let guide = UILayoutGuide()

        view.addLayoutGuide(guide)

        view.addSubview(editContainerView)
        view.addSubview(controlContainerView)

        editContainerView.accessibilityIdentifier = "app.muukii.pixel.editContainerView"
        controlContainerView.accessibilityIdentifier = "app.muukii.pixel.controlContainerView"

        editContainerView.translatesAutoresizingMaskIntoConstraints = false
        controlContainerView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
          guide.topAnchor.constraint(equalTo: topLayoutGuide.bottomAnchor),
          guide.rightAnchor.constraint(equalTo: view.rightAnchor),
          guide.leftAnchor.constraint(equalTo: view.leftAnchor),
          guide.widthAnchor.constraint(equalTo: guide.heightAnchor, multiplier: 1),

          {
            let c = editContainerView.topAnchor.constraint(equalTo: guide.topAnchor)
            c.priority = .defaultHigh
            return c
          }(),
          {
            let c = editContainerView.rightAnchor.constraint(equalTo: guide.rightAnchor)
            c.priority = .defaultHigh
            return c
          }(),
          {
            let c = editContainerView.leftAnchor.constraint(equalTo: guide.leftAnchor)
            c.priority = .defaultHigh
            return c
          }(),
          {
            let c = editContainerView.bottomAnchor.constraint(equalTo: guide.bottomAnchor)
            c.priority = .defaultHigh
            return c
          }(),

          editContainerView.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
          editContainerView.centerYAnchor.constraint(equalTo: guide.centerYAnchor),

          controlContainerView.topAnchor.constraint(equalTo: guide.bottomAnchor),
          controlContainerView.rightAnchor.constraint(equalTo: view.rightAnchor),
          controlContainerView.leftAnchor.constraint(equalTo: view.leftAnchor),
          {
            if #available(iOS 11.0, *) {
              return controlContainerView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
            } else {
              return controlContainerView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            }
          }(),
        ])
      }

      root: do {
        view.backgroundColor = Style.default.control.backgroundColor
      }

      edit: do {
        [
          cropView,
          previewView,
          maskingView,
        ].forEach { view in
          view.translatesAutoresizingMaskIntoConstraints = false
          editContainerView.addSubview(view)
          NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: view.superview!.topAnchor),
            view.rightAnchor.constraint(equalTo: view.superview!.rightAnchor),
            view.bottomAnchor.constraint(equalTo: view.superview!.bottomAnchor),
            view.leftAnchor.constraint(equalTo: view.superview!.leftAnchor),
          ])
        }
      }

      control: do {
        controlContainerView.addSubview(stackView)

        stackView.frame = stackView.bounds
        stackView.autoresizingMask = [.flexibleHeight, .flexibleWidth]
      }
    }
    
    stackView.push(
      viewModel.options.classes.control.rootControl.init(
        viewModel: viewModel,
        colorCubeControl: viewModel.options.classes.control.colorCubeControl.init(
          viewModel: viewModel
        )
      ),
      animated: false
    )

    subscriptions.formUnion(
      maskingView.attach(editingStack: viewModel.editingStack)
    )
    
    viewModel.sinkState(queue: .main) { [weak self] state in
      
      guard let self = self else { return }
      
      self.updateUI(state: state)
    }
    .store(in: &subscriptions)
    
    cropView.store.sinkState { [weak self] (state) in
      
      guard let self = self else { return }
      
      state.ifChanged(\.proposedCropAndRotate) { value in
        if let value = value {
          self.viewModel.set(proposedCropAndRotate: value)
        }
      }
    }
    .store(in: &subscriptions)
        
    viewModel.editingStack.start()
  }
  
  public override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
  }
  
  public override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    view.layoutIfNeeded()
  }
  
  // MARK: - Private Functions

  @objc
  private func didTapDoneButton() {
    callbacks.didEndEditing(self, viewModel.editingStack)
    delegate?.pixelEditViewController(self, didEndEditing: viewModel.editingStack)
  }

  @objc
  private func didTapCancelButton() {
    callbacks.didCancelEditing(self)
    delegate?.pixelEditViewControllerDidCancelEditing(in: self)
  }

  private func updateUI(state: Changes<PixelEditViewModel.State>) {
    if let paths = state.takeIfChanged(\.editingState.currentEdit.drawings.blurredMaskPaths) {
      maskingView.drawnPaths = paths
    }

    if let previewImage = state.takeIfChanged(\.editingState.previewCroppedAndEffectedImage) {
      maskingView.image = previewImage
    }

    if let brush = state.takeIfChanged(\.brush) {
      maskingView.brush = brush
    }

    if let mode = state.takeIfChanged(\.mode) {
      switch mode {
      case .adjustment:

        navigationItem.rightBarButtonItem = nil
        navigationItem.leftBarButtonItem = nil

        cropView.isHidden = false
        previewView.isHidden = true
        maskingView.isHidden = true
        maskingView.isUserInteractionEnabled = false

      case .masking:

        navigationItem.rightBarButtonItem = nil
        navigationItem.leftBarButtonItem = nil

        cropView.isHidden = true
        previewView.isHidden = false
        maskingView.isHidden = false

        maskingView.isUserInteractionEnabled = true

      case .editing:

        navigationItem.rightBarButtonItem = nil
        navigationItem.leftBarButtonItem = nil

        cropView.isHidden = true
        previewView.isHidden = false
        maskingView.isHidden = true

        maskingView.isUserInteractionEnabled = false

      case .preview:

        navigationItem.setHidesBackButton(true, animated: false)
        navigationItem.rightBarButtonItem = doneButton
        navigationItem.leftBarButtonItem = cancelButton

        previewView.isHidden = false
        cropView.isHidden = true
        maskingView.isHidden = false

        maskingView.isUserInteractionEnabled = false
      }

    }

    let editingState = state.map(\.editingState)
    
    editingState.ifChanged(\.aspectRatio) { aspectRatio in
      
      aspectConstraint?.isActive = false
      
      let newConstraint = editContainerView.widthAnchor.constraint(
        equalTo: editContainerView.heightAnchor,
        multiplier: aspectRatio.width / aspectRatio.height
      )
      
      NSLayoutConstraint.activate([
        newConstraint,
      ])
      
      aspectConstraint = newConstraint
    }
        
    editingState.ifChanged(\.isLoading) { isLoading in

      switch isLoading {
      case true:

        let loadingView = self.loadingView
        let touchGuardOverlayView = self.touchGuardOverlayView

        touchGuardOverlayView.backgroundColor = .init(white: 1, alpha: 0.5)

        view.addSubview(loadingView)
        view.addSubview(touchGuardOverlayView)

        touchGuardOverlayView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
          loadingView.leadingAnchor.constraint(equalTo: previewView.leadingAnchor),
          loadingView.trailingAnchor.constraint(equalTo: previewView.trailingAnchor),
          loadingView.topAnchor.constraint(equalTo: previewView.topAnchor),
          loadingView.bottomAnchor.constraint(equalTo: previewView.bottomAnchor),
          touchGuardOverlayView.leadingAnchor.constraint(equalTo: controlContainerView.leadingAnchor),
          touchGuardOverlayView.trailingAnchor.constraint(equalTo: controlContainerView.trailingAnchor),
          touchGuardOverlayView.topAnchor.constraint(equalTo: controlContainerView.topAnchor),
          touchGuardOverlayView.bottomAnchor.constraint(equalTo: controlContainerView.bottomAnchor),
        ])
        self.doneButton.isEnabled = false

      case false:
        self.loadingView.removeFromSuperview()
        self.touchGuardOverlayView.removeFromSuperview()
        self.doneButton.isEnabled = true
      }
    }
  }

//  private func didReceive(action: PixelEditContext.Action) {
//    switch action {
//
//    case .endAdjustment(let save):
//      setAspect(aspectRatio)
//      if save {
//        editingStack.setAdjustment(cropRect: adjustmentView.visibleExtent)
//        editingStack.commit()
//      } else {
//        syncUI(edit: editingStack.currentEdit)
//      }
//    case .endMasking(let save):
//
//  }
}
