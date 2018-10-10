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

public final class PixelEditViewController : UIViewController {

  public enum Mode {

    case crop
    case preview
  }

  private let previewView = ImagePreviewView()

  private let cropView = CropAndStraightenView()

  private let editContainerView = UIView()

  private let controlContainerView = UIView()

  private let cropButton = UIButton(type: .system)

  public let engine: ImageEngine

  private var previewEngine: PreviewImageEngine!

  public weak var delegate: PixelEditViewControllerDelegate?

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
          controlContainerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
          ])

      }

      edit: do {

        editContainerView.addSubview(cropView)
        editContainerView.addSubview(previewView)

        previewView.translatesAutoresizingMaskIntoConstraints = false
        cropView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
          cropView.topAnchor.constraint(equalTo: cropView.superview!.topAnchor),
          cropView.rightAnchor.constraint(equalTo: cropView.superview!.rightAnchor),
          cropView.bottomAnchor.constraint(equalTo: cropView.superview!.bottomAnchor),
          cropView.leftAnchor.constraint(equalTo: cropView.superview!.leftAnchor),

          previewView.topAnchor.constraint(equalTo: previewView.superview!.topAnchor),
          previewView.rightAnchor.constraint(equalTo: previewView.superview!.rightAnchor),
          previewView.bottomAnchor.constraint(equalTo: previewView.superview!.bottomAnchor),
          previewView.leftAnchor.constraint(equalTo: previewView.superview!.leftAnchor),
          ])

      }

      control: do {

        let stackView = ControlStackView()

        controlContainerView.addSubview(stackView)

        stackView.frame = stackView.bounds
        stackView.autoresizingMask = [.flexibleHeight, .flexibleWidth]

        stackView.push(TopControlView())

      }

      navigationBar: do {

        let doneButton = UIBarButtonItem(
          title: "Done",
          style: .plain,
          target: self,
          action: #selector(didTapDoneButton)
        )

        navigationItem.rightBarButtonItem = doneButton

      }

    }

    start: do {

      view.layoutIfNeeded()

      cropView.image = previewEngine.imageForCropping

      previewView.image = previewEngine.previewImage
    }

  }

  @objc
  private func presentCropViewController() {

    let cropViewController = CropViewController(engine: engine)

    cropViewController.modalTransitionStyle = .crossDissolve

    present(cropViewController, animated: true, completion: nil)

  }

  @objc
  private func didTapDoneButton() {

    print("done")
  }

}

private final class CropViewController : UIViewController {

  // MARK: - Properties

  private let cropView = CropAndStraightenView()

  private let cropButton = UIButton(type: .system)

  private let editContainerView = UIView()
  private let controlContainerView = UIView()

  public let engine: ImageEngine

  private var previewEngine: PreviewImageEngine!
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

        editContainerView.topAnchor.constraint(equalTo: view.topAnchor).isActive = true
        editContainerView.rightAnchor.constraint(equalTo: view.rightAnchor).isActive = true
        editContainerView.leftAnchor.constraint(equalTo: view.leftAnchor).isActive = true

        controlContainerView.topAnchor.constraint(equalTo: editContainerView.bottomAnchor).isActive = true
        controlContainerView.rightAnchor.constraint(equalTo: editContainerView.rightAnchor).isActive = true
        controlContainerView.leftAnchor.constraint(equalTo: editContainerView.leftAnchor).isActive = true
        controlContainerView.bottomAnchor.constraint(equalTo: view.bottomAnchor).isActive = true

      }



      control: do {

        controlContainerView.addSubview(cropButton)

        cropButton.setTitle("Crop", for: .normal)
        cropButton.translatesAutoresizingMaskIntoConstraints = false

        cropButton.topAnchor.constraint(equalTo: cropButton.superview!.topAnchor).isActive = true
        cropButton.bottomAnchor.constraint(equalTo: cropButton.superview!.bottomAnchor).isActive = true
        cropButton.centerXAnchor.constraint(equalTo: cropButton.superview!.centerXAnchor).isActive = true

        cropButton.addTarget(self, action: #selector(applyCrop), for: .touchUpInside)
      }
    }

    start: do {

      view.layoutIfNeeded()

      cropView.image = previewEngine.imageForCropping
    }

  }

  @objc
  private func applyCrop() {

    print(cropView.visibleExtent, engine.targetImage.extent)

  }


}
