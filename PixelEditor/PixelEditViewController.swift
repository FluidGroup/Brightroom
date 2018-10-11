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

//  func pixelEditViewController(_ controller: PixelEditViewController, )
}

public final class PixelEditContext {

  public enum Action {
    case setMode(PixelEditViewController.Mode)
    case endAdjustment(save: Bool)
  }

  fileprivate var didReceiveAction: (Action) -> Void = { _ in }

  fileprivate init() {

  }

  func action(_ action: Action) {
    didReceiveAction(action)
  }
}

public final class PixelEditViewController : UIViewController {

  public enum Mode {

    case adjustment
    case masking
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

  private lazy var doneButton = UIBarButtonItem(
    title: TODOL10n("Done"),
    style: .plain,
    target: self,
    action: #selector(didTapDoneButton)
  )

  public let engine: ImageEngine

  private var previewEngine: PreviewImageEngine!

  public weak var delegate: PixelEditViewControllerDelegate?

  public let context: PixelEditContext = .init()

  // MARK: - Initializers

  public convenience init(image: UIImage) {
    let engine = ImageEngine(targetImage: image)
    self.init(engine: engine)
  }

  public init(engine: ImageEngine) {
    self.engine = engine
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

        previewEngine = PreviewImageEngine.init(
          engine: engine,
          previewSize: CGSize(width: view.bounds.width, height: view.bounds.width)
        )

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

      edit: do {

        [
          adjustmentView,
          maskingView,
          previewView
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

        let stackView = ControlStackView()

        controlContainerView.addSubview(stackView)

        stackView.frame = stackView.bounds
        stackView.autoresizingMask = [.flexibleHeight, .flexibleWidth]

        stackView.push(TopControlView(context: context))

      }

    }

    bind: do {

      context.didReceiveAction = { [weak self] action in

        guard let self = self else { return }

        switch action {
        case .setMode(let mode):
          self.set(mode: mode)
        case .endAdjustment(let save):
          if save {
            self.previewEngine.setAdjustment(cropRect: self.adjustmentView.visibleExtent)
          }
        }
      }

    }

    start: do {

      previewEngine.delegate = self
      view.layoutIfNeeded()

      set(mode: mode)
    }

  }

  @objc
  private func didTapDoneButton() {

    let renderedImage = engine.render()
    print("done", renderedImage)
  }

  private func set(mode: Mode) {


    adjustmentView.isHidden = true
    previewView.isHidden = true
    maskingView.isHidden = true

    switch mode {
    case .adjustment:
      navigationItem.rightBarButtonItem = nil

      adjustmentView.isHidden = false

      adjustmentView.image = previewEngine.adjustmentImage
      if let croppingRect = engine.edit.croppingRect {
        adjustmentView.visibleExtent = croppingRect
      }
    case .masking:

      navigationItem.rightBarButtonItem = nil
      maskingView.isHidden = false

    case .preview:
      navigationItem.rightBarButtonItem = doneButton
      previewView.isHidden = false
      previewView.image = previewEngine.previewImage
    }

  }

}

extension PixelEditViewController : PreviewImageEngineDelegate {

  public func previewImageEngine(_ engine: PreviewImageEngine, didChangePreviewImage image: UIImage?) {
    previewView.image = image
  }

  public func previewImageEngine(_ engine: PreviewImageEngine, didChangeAdjustmentImage image: UIImage?) {

  }

}
