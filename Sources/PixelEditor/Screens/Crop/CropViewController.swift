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

/**
 A view controller that specifies how it crops in the image.
 
 You might use `CropView` to create a fully customized user interface.
 */
public final class CropViewController: UIViewController {
  public struct Handlers {
    public var didFinish: (CropViewController) -> Void = { _ in }
    public var didCancel: (CropViewController) -> Void = { _ in }
  }
  
  private let cropView: CropView
  private let aspectRatioControl: AspectRatioControl
  
  public let editingStack: EditingStack
  public var handlers = Handlers()
  
  private var subscriptions = Set<VergeAnyCancellable>()
      
  public init(editingStack: EditingStack) {
    self.editingStack = editingStack
    cropView = .init(editingStack: editingStack)
    aspectRatioControl = .init(originalAspectRatio: .init(editingStack.state.imageSize))
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
      $0.setImage(UIImage(named: "rotate", in: bundle, compatibleWith: nil), for: .normal)
      $0.tintColor = .systemGray
      $0.addTarget(self, action: #selector(handleRotateButton), for: .touchUpInside)
    }
    
    let aspectRatioButton = UIButton(type: .system)&>.do {
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
        // FIXME: Localize
        $0.setTitle("Cancel", for: .normal)
        $0.titleLabel?.font = UIFont.systemFont(ofSize: 17)
        $0.setTitleColor(UIColor.white, for: .normal)
        $0.addTarget(self, action: #selector(handleCancelButton), for: .touchUpInside)
      }
      
      let doneButton = UIButton(type: .system)&>.do {
        // FIXME: Localize
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
    view.addSubview(aspectRatioControl)
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
    
    aspectRatioControl&>.do {
      $0.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        $0.topAnchor.constraint(equalTo: cropView.bottomAnchor),
        $0.leftAnchor.constraint(equalTo: view.leftAnchor),
        $0.rightAnchor.constraint(equalTo: view.rightAnchor),
      ])
    }
    
    bottomStackView&>.do {
      $0.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        $0.topAnchor.constraint(equalTo: aspectRatioControl.bottomAnchor),
        $0.leftAnchor.constraint(equalTo: view.leftAnchor, constant: 16),
        $0.rightAnchor.constraint(equalTo: view.rightAnchor, constant: -16),
        $0.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        $0.heightAnchor.constraint(equalToConstant: 50),
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

private final class AspectRatioControl: PixelEditorCodeBasedView {
  private struct State: Equatable {
    enum Direction {
      case vertical
      case horizontal
    }
    
    let rectangleApectRatios: [PixelAspectRatio] = [
      .init(width: 16, height: 9),
      .init(width: 10, height: 8),
      .init(width: 7, height: 5),
      .init(width: 4, height: 3),
      .init(width: 5, height: 3),
      .init(width: 3, height: 2),
    ]
    
    let originalAspectRatio: PixelAspectRatio
    
    var selectedAspectRatio: PixelAspectRatio?
    
    var direction: Direction = .vertical
    
    var canSelectDirection: Bool {
      guard let selectedAspectRatio = selectedAspectRatio else {
        return false
      }
      
      guard selectedAspectRatio != .square else {
        return false
      }
      
      return true
    }
  }
  
  struct Handlers {}
  
  var handlers: Handlers = .init()
  
  private let horizontalButton = UIButton(type: .system)
  private let verticalButton = UIButton(type: .system)
  
  private let scrollView = UIScrollView()
  
  private let originalButton = UIButton(type: .system)
  private let freeformButton = UIButton(type: .system)
  private let aspectSquareButton = UIButton(type: .system)
  
  private let store: UIStateStore<State, Never>
  private var subscriptions = Set<VergeAnyCancellable>()
  
  init(originalAspectRatio: PixelAspectRatio) {
    store = .init(initialState: .init(originalAspectRatio: originalAspectRatio))
    
    super.init(frame: .zero)
    
    let directionStackView = UIStackView()&>.do {
      $0.addArrangedSubview(horizontalButton)
      $0.addArrangedSubview(verticalButton)
    }
    
    var buttons: [PixelAspectRatio: UIButton] = [:]
    
    let itemsStackView = UIStackView()&>.do { stackView in
      
      stackView.spacing = 20
      
      [
        originalButton,
        freeformButton,
        aspectSquareButton,
      ]
      .forEach {
        stackView.addArrangedSubview($0)
      }
      
      store.state.rectangleApectRatios.forEach { ratio in
        
        let button = UIButton(type: .system)
        
        stackView.addArrangedSubview(button)
        
        button.onTap { [unowned store] in
          store.commit {
            $0.selectedAspectRatio = ratio
          }
        }
        
        buttons[ratio] = button
      }
    }
    
    originalButton&>.do {
      // FIXME: Localize
      $0.setTitle("ORIGINAL", for: .normal)
      $0.onTap { [unowned store] in
        store.commit {
          $0.selectedAspectRatio = $0.originalAspectRatio
        }
      }
      
    }
    
    freeformButton&>.do {
      // FIXME: Localize
      $0.setTitle("FREEFORM", for: .normal)
      $0.onTap { [unowned store] in
        store.commit {
          $0.selectedAspectRatio = nil
        }
      }
    }
    
    aspectSquareButton&>.do {
      // FIXME: Localize
      $0.setTitle("SQUARE", for: .normal)
      $0.onTap { [unowned store] in
        store.commit {
          $0.selectedAspectRatio = .square
        }
      }
    }
    
    addSubview(directionStackView)
    addSubview(scrollView)
    scrollView.addSubview(itemsStackView)
    
    itemsStackView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      itemsStackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      itemsStackView.rightAnchor.constraint(equalTo: scrollView.contentLayoutGuide.rightAnchor),
      itemsStackView.leftAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leftAnchor),
      itemsStackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      
      itemsStackView.topAnchor.constraint(equalTo: scrollView.frameLayoutGuide.topAnchor),
      itemsStackView.bottomAnchor.constraint(equalTo: scrollView.frameLayoutGuide.bottomAnchor),
    ])
    
    directionStackView&>.do {
      $0.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        $0.topAnchor.constraint(equalTo: topAnchor),
        $0.rightAnchor.constraint(equalTo: rightAnchor),
        $0.leftAnchor.constraint(equalTo: leftAnchor),
      ])
    }
    
    scrollView&>.do {
      $0.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        $0.topAnchor.constraint(equalTo: directionStackView.bottomAnchor),
        $0.rightAnchor.constraint(equalTo: rightAnchor),
        $0.leftAnchor.constraint(equalTo: leftAnchor),
        $0.bottomAnchor.constraint(equalTo:bottomAnchor),
      ])
      $0.contentInset = .init(top: 0, left: 24, bottom: 0, right: 24)
      $0.showsHorizontalScrollIndicator = false
    }
    
    store.sinkState { [weak self] state in
      
      guard let self = self else { return }
      
      state.ifChanged(\.canSelectDirection) { canSelectDirection in
        
        self.horizontalButton.isEnabled = canSelectDirection
        self.verticalButton.isEnabled = canSelectDirection
      }
      
      state.ifChanged(\.direction) { direction in
        
        switch direction {
        case .horizontal:
          
          state.rectangleApectRatios.forEach { ratio in
            buttons[ratio]?.setTitle("\(Int(ratio.width)):\(Int(ratio.height))", for: .normal)
          }
          
        case .vertical:
          
          state.rectangleApectRatios.forEach { ratio in
            buttons[ratio]?.setTitle("\(Int(ratio.height)):\(Int(ratio.width))", for: .normal)
          }
        }
      }
    }
    .store(in: &subscriptions)
  }
}
