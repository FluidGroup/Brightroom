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

import UIKit

import PixelEngine


public protocol PixelEditViewControllerDelegate : class {

  func pixelEditViewController(_ controller: PixelEditViewController, didEndEditing editingStack: EditingStack)
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
  
  public final class Callbacks {
    public var didEndEditing: (PixelEditViewController, EditingStack) -> Void = { _, _ in }
    public var didCancelEditing: (PixelEditViewController) -> Void = { _ in }
  }

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
  
  public weak var delegate: PixelEditViewControllerDelegate?
  
  public let callbacks: Callbacks = .init()
  
  public lazy var context: PixelEditContext = .init(options: options)
  
  public let options: Options
  
  public private(set) var editingStack: EditingStack!
  
  // MARK: - Private Propaties

  private let maskingView = BlurredMosaicView()

  private let previewView = ImagePreviewView()

  private let adjustmentView = CropAndStraightenView()

  private let editContainerView = UIView()

  private let controlContainerView = UIView()

  private let cropButton = UIButton(type: .system)

  private let stackView = ControlStackView()
  
  private let doneButtonTitle: String
  
  private var aspectConstraint: NSLayoutConstraint?

  private lazy var doneButton = UIBarButtonItem(
    title: doneButtonTitle,
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
  private var colorCubeStorage: ColorCubeStorage = .default

  // MARK: - Initializers

  public convenience init(
    editingStack: EditingStack,
    doneButtonTitle: String = L10n.done,
    options: Options = .current
    ) {
    self.init(source: editingStack.source, options: options)
    self.editingStack = editingStack
  }
  
  public convenience init(
    image: UIImage,
    doneButtonTitle: String = L10n.done,
    colorCubeStorage: ColorCubeStorage = .default,
    options: Options = .current
    ) {
    let source = ImageSource(source: image)
    self.init(source: source, colorCubeStorage: colorCubeStorage, options: options)
  }

  public init(
    source: ImageSource,
    doneButtonTitle: String = L10n.done,
    colorCubeStorage: ColorCubeStorage = .default,
    options: Options = .current
    ) {
    self.imageSource = source
    self.options = options
    self.colorCubeStorage = colorCubeStorage
    self.doneButtonTitle = doneButtonTitle
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

        if editingStack == nil {
          editingStack = SquareEditingStack.init(
            source: imageSource,
            previewSize: CGSize(width: view.bounds.width, height: view.bounds.width),
            colorCubeStorage: colorCubeStorage
          )
        }

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
          }()
          ])

        setAspect(editingStack.aspectRatio)
        
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

        stackView.push(
          options.classes.control.rootControl.init(
            context: context,
            colorCubeControl: options.classes.control.colorCubeControl.init(
              context: context,
              originalImage: editingStack.cubeFilterPreviewSourceImage,
              filters: editingStack.availableColorCubeFilters
            )
          ),
          animated: false
        )
        stackView.notify(changedEdit: editingStack.currentEdit)

      }

    }

    bind: do {

      context.didReceiveAction = { [weak self] action in

        guard let self = self else { return }

        self.didReceive(action: action)

      }

    }

    start: do {

      editingStack.delegate = self
      view.layoutIfNeeded()
      
      previewView.originalImage = editingStack.originalPreviewImage
      previewView.image = editingStack.previewImage
      maskingView.image = editingStack.previewImage
      maskingView.drawnPaths = editingStack.currentEdit.blurredMaskPaths

      set(mode: mode)
    }

  }
    
  // MARK: - Private Functions
  
  private func setAspect(_ size: CGSize) {
    
    aspectConstraint?.isActive = false
    
    let newConstraint = editContainerView.widthAnchor.constraint(
      equalTo: editContainerView.heightAnchor,
      multiplier: size.width / size.height
    )
    
    NSLayoutConstraint.activate([
      newConstraint
      ])
    
    aspectConstraint = newConstraint
    
  }

  @objc
  private func didTapDoneButton() {

    callbacks.didEndEditing(self, editingStack)
    delegate?.pixelEditViewController(self, didEndEditing: editingStack)
  }
  
  @objc
  private func didTapCancelButton() {
    
    callbacks.didCancelEditing(self)
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

      if maskingView.image != editingStack.previewImage {
        maskingView.image = editingStack.previewImage
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
      
      if maskingView.image != editingStack.previewImage {
        maskingView.image = editingStack.previewImage
      }

    }

  }

  private func syncUI(edit: EditingStack.Edit) {

    if !adjustmentView.isHidden {
      updateAdjustmentUI()
    }
    
    maskingView.drawnPaths = editingStack.currentEdit.blurredMaskPaths
  }
  
  private func updateAdjustmentUI() {
    
    let edit = editingStack.currentEdit
    
    if adjustmentView.image != editingStack.adjustmentImage {
      adjustmentView.image = editingStack.adjustmentImage
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
      setAspect(editingStack.aspectRatio)
      if save {
        editingStack.setAdjustment(cropRect: adjustmentView.visibleExtent)
        editingStack.commit()
      } else {
        syncUI(edit: editingStack.currentEdit)
      }
    case .endMasking(let save):
      if save {
        editingStack.set(blurringMaskPaths: maskingView.drawnPaths)
        editingStack.commit()
      } else {
        syncUI(edit: editingStack.currentEdit)
      }
    case .removeAllMasking:
      editingStack.set(blurringMaskPaths: [])
      editingStack.commit()
      syncUI(edit: editingStack.currentEdit)
    case .setFilter(let closure):
      editingStack.set(filters: closure)
    case .commit:
      editingStack.commit()
    case .undo:
      editingStack.undo()
    case .revert:
      editingStack.revert()
    }
  }

}

extension PixelEditViewController : EditingStackDelegate {

  public func editingStack(_ stack: EditingStack, didChangeCurrentEdit edit: EditingStack.Edit) {
    
    EditorLog.debug("[EditingStackDelegate] didChagneCurrentEdit")
    
    UIView.performWithoutAnimation {
      self.previewView.image = stack.previewImage
      self.previewView.originalImage = stack.originalPreviewImage
      if !self.maskingView.isHidden {
        self.maskingView.image = stack.previewImage
      }
    }
    
    syncUI(edit: edit)
    stackView.notify(changedEdit: edit)
    
  }

}
