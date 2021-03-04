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

import Foundation

import PixelEngine
import Verge

public final class CropViewController: UIViewController {
  public struct Handlers {
    public var didFinish: () -> Void = {}
  }

  private let cropView: CropView

  public let editingStack: EditingStack
  public var handlers = Handlers()

  private var bag = Set<VergeAnyCancellable>()

  public init(editingStack: EditingStack) {
    self.editingStack = editingStack
    self.cropView = .init(editingStack: editingStack)
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  public required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override public func viewDidLoad() {
    super.viewDidLoad()

    view.backgroundColor = .white

    cropView.setCropInsideOverlay(CropView.CropInsideOverlayRuleOfThirdsView())
    cropView.setCropOutsideOverlay(CropView.CropOutsideOverlayBlurredView())

    let topStackView = UIStackView()&>.do {
      let rotateButton = UIButton(type: .system)&>.do {
        // TODO: Localize
        $0.setTitle("Rotate", for: .normal)
        $0.addTarget(self, action: #selector(handleRotateButton), for: .touchUpInside)
      }

      let resetButton = UIButton(type: .system)&>.do {
        // TODO: Localize
        $0.setTitle("Reset", for: .normal)
        $0.addTarget(self, action: #selector(handleResetButton), for: .touchUpInside)
      }
      
      let aspectRatioButton = UIButton(type: .system)&>.do {
        // TODO: Localize
        $0.setTitle("AspectRatio", for: .normal)
        $0.addTarget(self, action: #selector(handleAspectRatioButton), for: .touchUpInside)
      }

      $0.addArrangedSubview(rotateButton)
      $0.addArrangedSubview(resetButton)
      $0.addArrangedSubview(aspectRatioButton)
    }

    let bottomStackView = UIStackView()&>.do {
      let cancelButton = UIButton(type: .system)&>.do {
        // TODO: Localize
        $0.setTitle("Cancel", for: .normal)
        $0.addTarget(self, action: #selector(handleCancelButton), for: .touchUpInside)
      }

      let doneButton = UIButton(type: .system)&>.do {
        // TODO: Localize
        $0.setTitle("Done", for: .normal)
        $0.addTarget(self, action: #selector(handleDoneButton), for: .touchUpInside)
      }
      $0.addArrangedSubview(cancelButton)
      $0.addArrangedSubview(doneButton)
    }

    view.addSubview(cropView)
    view.addSubview(topStackView)
    view.addSubview(bottomStackView)

    topStackView&>.do {
      $0.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        $0.topAnchor.constraint(equalTo: view.topAnchor),
        $0.leftAnchor.constraint(equalTo: view.leftAnchor),
        $0.rightAnchor.constraint(equalTo: view.rightAnchor),
      ])
    }

    cropView&>.do {
      $0.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        $0.topAnchor.constraint(equalTo: topStackView.bottomAnchor),
        $0.leftAnchor.constraint(equalTo: view.leftAnchor),
        $0.rightAnchor.constraint(equalTo: view.rightAnchor),
      ])
    }

    bottomStackView&>.do {
      $0.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        $0.topAnchor.constraint(equalTo: cropView.bottomAnchor),
        $0.leftAnchor.constraint(equalTo: view.leftAnchor),
        $0.rightAnchor.constraint(equalTo: view.rightAnchor),
        $0.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
      ])
    }
  
    cropView.store.sinkState { [weak self] state in

      guard let self = self else { return }

      state.ifChanged(\.proposedCropAndRotate) { cropAndRotate in
        guard let cropAndRotate = cropAndRotate else { return }
        self.editingStack.crop(cropAndRotate)
      }
    }
    .store(in: &bag)
  }

  @objc private func handleRotateButton() {
    let rotation = cropView.store.state.proposedCropAndRotate?.rotation.next()
    rotation.map {
      cropView.setRotation($0)
    }
  }
  
  @objc private func handleAspectRatioButton() {
    cropView.setCroppingAspectRatio(.init(width: 16, height: 9))
  }

  @objc private func handleResetButton() {
    cropView.resetCropAndRotate()
  }

  @objc private func handleCancelButton() {
    handlers.didFinish()
  }

  @objc private func handleDoneButton() {
    handlers.didFinish()
  }
}
