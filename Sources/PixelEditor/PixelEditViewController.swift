//
//  PixelEditViewController.swift
//  PixelEditor
//
//  Created by muukii on 10/9/18.
//  Copyright © 2018 eure. All rights reserved.
//

import UIKit

import PixelEngine


public protocol PixelEditViewControllerDelegate : class {

  func pixelEditViewController(_ controller: PixelEditViewController, didEndEditing image: UIImage)
  func pixelEditViewControllerDidCancelEditing(in controller: PixelEditViewController)
  
}

public final class PixelEditContext {

  public enum Action {
    case setTitle(String)
    case setMode(PixelEditViewController.Mode)
    case endAdjustment(save: Bool)
    case endMasking(save: Bool)
    case removeAllMasking

    case setFilter((inout EditingStack.Edit.Filters) -> Void)

    case commit
    case revert
    case undo
  }

  fileprivate var didReceiveAction: (Action) -> Void = { _ in }
  
  public let options: Options

  fileprivate init(options: Options) {
    self.options = options
  }

  func action(_ action: Action) {
    self.didReceiveAction(action)
  }
}

public final class PixelEditViewController : UIViewController {

  public enum Mode {

    case adjustment
    case masking
    case editing
    case preview
  }

  public var mode: Mode = .preview {
    didSet {
      guard oldValue != mode else { return }
      set(mode: mode)
    }
  }

  private let maskingView = BlurredMosaicView()

  private let previewView = ImagePreviewView()

  private let adjustmentView = CropAndStraightenView()

  private let editContainerView = UIView()

  private let controlContainerView = UIView()

  private let cropButton = UIButton(type: .system)

  private let stackView = ControlStackView()

  private lazy var doneButton = UIBarButtonItem(
    title: L10n.done,
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

  private let imageSource: ImageSource
  private var stack: SquareEditingStack!

  public weak var delegate: PixelEditViewControllerDelegate?

  public lazy var context: PixelEditContext = .init(options: options)
  
  public let options: Options

  // MARK: - Initializers

  public convenience init(image: UIImage, options: Options = .default) {
    let surce = ImageSource(source: image)
    self.init(source: surce, options: options)
  }

  public convenience init(stack: SquareEditingStack, options: Options = .default) {
    self.init(source: stack.source, options: options)
    self.stack = stack
  }

  public init(source: ImageSource, options: Options = .default) {
    self.imageSource = source
    self.options = options
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  public required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Functions

  public override func viewDidLoad() {
    super.viewDidLoad()

    layout: do {

      root: do {

        if stack == nil {
          stack = SquareEditingStack.init(
            source: imageSource,
            previewSize: CGSize(width: view.bounds.width, height: view.bounds.width),
            colorCubeFilters: ColorCubeStorage.filters
          )
        }

        view.backgroundColor = .white

        view.addSubview(editContainerView)
        view.addSubview(controlContainerView)

        editContainerView.translatesAutoresizingMaskIntoConstraints = false
        controlContainerView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
          editContainerView.topAnchor.constraint(equalTo: topLayoutGuide.bottomAnchor),
          editContainerView.rightAnchor.constraint(equalTo: view.rightAnchor),
          editContainerView.leftAnchor.constraint(equalTo: view.leftAnchor),
          editContainerView.widthAnchor.constraint(equalTo: editContainerView.heightAnchor, multiplier: 1),

          controlContainerView.topAnchor.constraint(equalTo: editContainerView.bottomAnchor),
          controlContainerView.rightAnchor.constraint(equalTo: editContainerView.rightAnchor),
          controlContainerView.leftAnchor.constraint(equalTo: editContainerView.leftAnchor),
          {
            if #available(iOS 11.0, *) {
              return controlContainerView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
            } else {
              return controlContainerView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            }
          }()
          ])

      }

      root: do {
        view.backgroundColor = Style.default.control.backgroundColor
      }

      edit: do {

        [
          adjustmentView,
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

        // TODO: Make customizable
        stackView.push(
          options.classes.control.rootControl.init(
            context: context,
            colorCubeControlView: options.classes.control.colorCubeControl.init(
              context: context,
              originalImage: stack.cubeFilterPreviewSourceImage,
              filters: stack.availableColorCubeFilters
            )
          )
        )
        stackView.notify(changedEdit: stack.currentEdit)

      }

    }

    bind: do {

      context.didReceiveAction = { [weak self] action in

        guard let self = self else { return }

        self.didReceive(action: action)

      }

    }

    start: do {

      stack.delegate = self
      view.layoutIfNeeded()
      
      previewView.originalImage = stack.originalPreviewImage
      previewView.image = stack.previewImage
      maskingView.image = stack.previewImage
      maskingView.drawnPaths = stack.currentEdit.blurredMaskPaths

      set(mode: mode)
    }

  }

  @objc
  private func didTapDoneButton() {

    let image = stack.makeRenderer().render()

    delegate?.pixelEditViewController(self, didEndEditing: image)
  }
  
  @objc
  private func didTapCancelButton() {
        
    delegate?.pixelEditViewControllerDidCancelEditing(in: self)
  }

  private func set(mode: Mode) {
    
    switch mode {
    case .adjustment:

      navigationItem.rightBarButtonItem = nil
      navigationItem.leftBarButtonItem = nil

      adjustmentView.isHidden = false
      previewView.isHidden = true
      maskingView.isHidden = true
      maskingView.isUserInteractionEnabled = false

      didReceive(action: .setTitle(L10n.editAdjustment))
      
      updateAdjustmentUI()

    case .masking:

      navigationItem.rightBarButtonItem = nil
      navigationItem.leftBarButtonItem = nil
      didReceive(action: .setTitle(L10n.editMask))

      adjustmentView.isHidden = true
      previewView.isHidden = false
      maskingView.isHidden = false
      
      maskingView.isUserInteractionEnabled = true

      if maskingView.image != stack.previewImage {
        maskingView.image = stack.previewImage
      }

    case .editing:

      navigationItem.rightBarButtonItem = nil
      navigationItem.leftBarButtonItem = nil

      adjustmentView.isHidden = true
      previewView.isHidden = false
      maskingView.isHidden = true

      maskingView.isUserInteractionEnabled = false

    case .preview:

      navigationItem.setHidesBackButton(true, animated: false)
      navigationItem.rightBarButtonItem = doneButton
      navigationItem.leftBarButtonItem = cancelButton
      
      didReceive(action: .setTitle(""))

      previewView.isHidden = false
      adjustmentView.isHidden = true
      maskingView.isHidden = false

      maskingView.isUserInteractionEnabled = false
      
      if maskingView.image != stack.previewImage {
        maskingView.image = stack.previewImage
      }

    }

  }

  private func syncUI(edit: EditingStack.Edit) {

    if !adjustmentView.isHidden {
      updateAdjustmentUI()
    }
    
    maskingView.drawnPaths = stack.currentEdit.blurredMaskPaths
  }
  
  private func updateAdjustmentUI() {
    
    let edit = stack.currentEdit
    
    if adjustmentView.image != stack.adjustmentImage {
      adjustmentView.image = stack.adjustmentImage
    }
    
    if let cropRect = edit.cropRect {
      adjustmentView.visibleExtent = cropRect
    }
  }

  private func didReceive(action: PixelEditContext.Action) {
    switch action {
    case .setTitle(let title):
      navigationItem.title = title
    case .setMode(let mode):
      set(mode: mode)
    case .endAdjustment(let save):
      if save {
        stack.setAdjustment(cropRect: adjustmentView.visibleExtent)
        stack.commit()
      } else {
        syncUI(edit: stack.currentEdit)
      }
    case .endMasking(let save):
      if save {
        stack.set(blurringMaskPaths: maskingView.drawnPaths)
        stack.commit()
      } else {
        syncUI(edit: stack.currentEdit)
      }
    case .removeAllMasking:
      stack.set(blurringMaskPaths: [])
      stack.commit()
      syncUI(edit: stack.currentEdit)
    case .setFilter(let closure):
      stack.set(filters: closure)   
    case .commit:
      stack.commit()
    case .undo:
      stack.undo()
    case .revert:
      stack.revert()
    }
  }

}

extension PixelEditViewController : EditingStackDelegate {

  public func editingStack(_ stack: EditingStack, didChangeCurrentEdit edit: EditingStack.Edit) {
    syncUI(edit: edit)
    previewView.image = stack.previewImage
    previewView.originalImage = stack.originalPreviewImage
    if !maskingView.isHidden {
      maskingView.image = stack.previewImage
    }
    stackView.notify(changedEdit: edit)
    EditorLog.debug("[EditingStackDelegate] didChagneCurrentEdit")
  }

}
