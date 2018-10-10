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

        cropView.translatesAutoresizingMaskIntoConstraints = false
        cropView.topAnchor.constraint(equalTo: cropView.superview!.topAnchor).isActive = true
        cropView.rightAnchor.constraint(equalTo: cropView.superview!.rightAnchor).isActive = true
        cropView.bottomAnchor.constraint(equalTo: cropView.superview!.bottomAnchor).isActive = true
        cropView.leftAnchor.constraint(equalTo: cropView.superview!.leftAnchor).isActive = true

        cropView.widthAnchor.constraint(equalTo: cropView.heightAnchor, multiplier: 1).isActive = true

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
