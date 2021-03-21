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

import Verge

#if !COCOAPODS
import PixelEngine
#endif

public final class CropViewController: UIViewController {
  public struct Handlers {
    public var didFinish: (CropViewController) -> Void = { _ in }
    public var didCancel: (CropViewController) -> Void = { _ in }
  }

  private let cropView: CropView

  public let editingStack: EditingStack
  public var handlers = Handlers()

  private var subscriptions = Set<VergeAnyCancellable>()

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

    cropView.isAutoApplyEditingStackEnabled = true
    view.backgroundColor = .black
    view.clipsToBounds = true
    
    let resetButton = UIButton(type: .system)&>.do {
      // TODO: Localize
      $0.setTitle("RESET", for: .normal)
      $0.titleLabel?.font = UIFont.systemFont(ofSize: 15)
      $0.setTitleColor(UIColor.systemYellow, for: .normal)
      $0.addTarget(self, action: #selector(handleResetButton), for: .touchUpInside)
      $0.isHidden = true
    }
    
    let rotateButton = UIButton(type: .system)&>.do {
      // TODO: Localize
      $0.setImage(UIImage(named: "rotate", in: bundle, compatibleWith: nil), for: .normal)
      $0.tintColor = .systemGray
      $0.addTarget(self, action: #selector(handleRotateButton), for: .touchUpInside)
    }
    
    let aspectRatioButton = UIButton(type: .system)&>.do {
      // TODO: Localize
      $0.setImage(UIImage(named: "aspectratio", in: bundle, compatibleWith: nil), for: .normal)
      $0.tintColor = .systemGray
      $0.addTarget(self, action: #selector(handleAspectRatioButton), for: .touchUpInside)
    }

    let topStackView = UIStackView()&>.do {

      $0.addArrangedSubview(rotateButton)
      $0.addArrangedSubview(resetButton)
      $0.addArrangedSubview(aspectRatioButton)
      $0.distribution = .equalSpacing
    }

    let bottomStackView = UIStackView()&>.do {
      let cancelButton = UIButton(type: .system)&>.do {
        // TODO: Localize
        $0.setTitle("Cancel", for: .normal)
        $0.titleLabel?.font = UIFont.systemFont(ofSize: 17)
        $0.setTitleColor(UIColor.white, for: .normal)
        $0.addTarget(self, action: #selector(handleCancelButton), for: .touchUpInside)
      }

      let doneButton = UIButton(type: .system)&>.do {
        // TODO: Localize
        $0.setTitle("Done", for: .normal)
        $0.titleLabel?.font = UIFont.systemFont(ofSize: 17)
        $0.setTitleColor(UIColor.systemYellow, for: .normal)
        $0.addTarget(self, action: #selector(handleDoneButton), for: .touchUpInside)
      }
      $0.addArrangedSubview(cancelButton)
      $0.addArrangedSubview(doneButton)
      $0.distribution = .equalSpacing
      $0.axis = .horizontal
      $0.alignment = .fill
    }

    view.addSubview(cropView)
    view.addSubview(topStackView)
    view.addSubview(bottomStackView)

    topStackView&>.do {
      $0.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        $0.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
        $0.leftAnchor.constraint(equalTo: view.leftAnchor, constant: 16),
        $0.rightAnchor.constraint(equalTo: view.rightAnchor, constant: -16),
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
        $0.leftAnchor.constraint(equalTo: view.leftAnchor, constant: 16),
        $0.rightAnchor.constraint(equalTo: view.rightAnchor, constant: -16),
        $0.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        $0.heightAnchor.constraint(equalToConstant: 50)
      ])
    }
    
    UIView.performWithoutAnimation {
      view.layoutIfNeeded()
    }
    
    editingStack.sinkState { state in
      
      state.ifChanged(\.hasUncommitedChanges) { hasChanges in
        resetButton.isHidden = !hasChanges
      }
      
    }
    .store(in: &subscriptions)
        
    editingStack.start()
  }

  @objc private func handleRotateButton() {
    let rotation = cropView.store.state.proposedCrop.rotation.next()
    cropView.setRotation(rotation)
  }
  
  @objc private func handleAspectRatioButton() {
    cropView.setCroppingAspectRatio(.init(width: 16, height: 9))
  }

  @objc private func handleResetButton() {
    cropView.resetCrop()
  }

  @objc private func handleCancelButton() {
    handlers.didCancel(self)
  }

  @objc private func handleDoneButton() {
    cropView.applyEditingStack()
    handlers.didFinish(self)
  }
}
