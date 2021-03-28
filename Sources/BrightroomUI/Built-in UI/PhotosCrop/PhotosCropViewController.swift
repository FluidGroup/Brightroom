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

/**
 Apple's Photos app like crop view controller.
 
 You might use `CropView` to create a fully customized user interface.
 */
public final class PhotosCropViewController: UIViewController {
  
  public struct LocalizedStrings {
    public var button_done_title: String = "Done"
    public var button_cancel_title: String = "Cancel"
    public var button_reset_title: String = "Reset"
    public var button_aspectratio_original: String = "ORIGINAL"
    public var button_aspectratio_freeform: String = "FREEFORM"
    public var button_aspectratio_square: String = "SQUARE"
    
    public init() {}
  }
  
  public struct Options: Equatable {
    
    public enum AspectRatioOptions: Equatable {
      case selectable
      case fixed(PixelAspectRatio?)
    }
    
    public var aspectRatioOptions: AspectRatioOptions = .selectable
    
    public init() {
      
    }
  }
  
  public struct Handlers {
    public var didFinish: (PhotosCropViewController) -> Void = { _ in }
    public var didCancel: (PhotosCropViewController) -> Void = { _ in }
  }
  
  private struct State: Equatable {
    var isSelectingAspectRatio = false
    var options: Options
  }
  
  // MARK: - Properties
  
  private let store: UIStateStore<State, Never>
  
  private let cropView: CropView
  private var aspectRatioControl: PhotosCropAspectRatioControl?
  
  public let editingStack: EditingStack
  public var handlers = Handlers()
      
  private let doneButton = UIButton(type: .system)
  private let cancelButton = UIButton(type: .system)
  private let aspectRatioButton = UIButton(type: .system)
  private let resetButton = UIButton(type: .system)
  private let rotateButton = UIButton(type: .system)
  
  private let aspectRatioControlLayoutGuide = UILayoutGuide()
    
  private var subscriptions = Set<VergeAnyCancellable>()
  private var hasSetupLoadedUICompleted = false
  
  public var localizedStrings: LocalizedStrings
  
  // MARK: - Initializers
        
  public init(
    editingStack: EditingStack,
    options: Options = .init(),
    localizedStrings: LocalizedStrings = .init()
  ) {
    self.localizedStrings = localizedStrings
    self.store = .init(initialState: .init(options: options))
    self.editingStack = editingStack
    cropView = .init(editingStack: editingStack)
    super.init(nibName: nil, bundle: nil)
  }
  
  /**
   Creates an instance for using as standalone.
   
   This initializer offers us to get cropping function without detailed setup.
   To get a result image, call `renderImage()`.
   */
  public convenience init(
    imageProvider: ImageProvider,
    options: Options = .init(),
    localizedStrings: LocalizedStrings = .init()
  ) {
    self.init(
      editingStack: .init(
        imageProvider: imageProvider
      ),
      options: options,
      localizedStrings: localizedStrings
    )
  }
  
  @available(*, unavailable)
  public required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  // MARK: - Functions
  
  /**
   Renders an image according to the editing.
   
   - Attension: This operation can be run background-thread.
   */
  public func renderImage(options: ImageRenderer.Options, completion: @escaping (Result<ImageRenderer.Rendered, Error>) -> Void) {
    do {
      try editingStack.makeRenderer().render(options: options, completion: completion)
    } catch {
      completion(.failure(error))
    }
  }
  
  override public func viewDidLoad() {
    super.viewDidLoad()
    
    editingStack.start()
    cropView.isAutoApplyEditingStackEnabled = true
    view.backgroundColor = .black
    view.clipsToBounds = true
    
    aspectRatioButton&>.do {
      $0.setImage(UIImage(named: "aspectratio", in: bundle, compatibleWith: nil), for: .normal)
      $0.tintColor = .systemGray
      $0.addTarget(self, action: #selector(handleAspectRatioButton), for: .touchUpInside)
    }
    
    resetButton&>.do {
      // TODO: Localize
      $0.setTitle(localizedStrings.button_reset_title, for: .normal)
      $0.titleLabel?.font = UIFont.systemFont(ofSize: 14)
      $0.setTitleColor(UIColor.systemYellow, for: .normal)
      $0.addTarget(self, action: #selector(handleResetButton), for: .touchUpInside)
      $0.isHidden = true
    }
    
    rotateButton&>.do {
      $0.setImage(UIImage(named: "rotate", in: bundle, compatibleWith: nil), for: .normal)
      $0.tintColor = .systemGray
      $0.addTarget(self, action: #selector(handleRotateButton), for: .touchUpInside)
    }
    
    let topStackView = UIStackView()&>.do {
      $0.addArrangedSubview(rotateButton)
      $0.addArrangedSubview(resetButton)
      $0.addArrangedSubview(aspectRatioButton)
      $0.distribution = .equalSpacing
    }

    cancelButton&>.do {
      $0.setTitle(localizedStrings.button_cancel_title, for: .normal)
      $0.titleLabel?.font = UIFont.systemFont(ofSize: 17)
      $0.setTitleColor(UIColor.white, for: .normal)
      $0.addTarget(self, action: #selector(handleCancelButton), for: .touchUpInside)
    }
        
    doneButton&>.do {
      $0.setTitle(localizedStrings.button_done_title, for: .normal)
      $0.titleLabel?.font = UIFont.systemFont(ofSize: 17)
      $0.setTitleColor(UIColor.systemYellow, for: .normal)
      $0.setTitleColor(UIColor.darkGray, for: .disabled)
      $0.addTarget(self, action: #selector(handleDoneButton), for: .touchUpInside)
    }
    
    let bottomStackView = UIStackView()&>.do {
      $0.addArrangedSubview(cancelButton)
      $0.addArrangedSubview(doneButton)
      $0.distribution = .equalSpacing
      $0.axis = .horizontal
      $0.alignment = .fill
    }
    
    view.addSubview(cropView)
    view.addSubview(topStackView)
    view.addSubview(bottomStackView)
    
    view.addLayoutGuide(aspectRatioControlLayoutGuide)
    
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
    
    aspectRatioControlLayoutGuide&>.do {
      NSLayoutConstraint.activate([
        $0.topAnchor.constraint(equalTo: cropView.bottomAnchor),
        $0.leftAnchor.constraint(equalTo: view.leftAnchor),
        $0.rightAnchor.constraint(equalTo: view.rightAnchor),
      ])
    }
    
    bottomStackView&>.do {
      $0.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        $0.topAnchor.constraint(equalTo: aspectRatioControlLayoutGuide.bottomAnchor),
        $0.leftAnchor.constraint(equalTo: view.leftAnchor, constant: 16),
        $0.rightAnchor.constraint(equalTo: view.rightAnchor, constant: -16),
        $0.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        $0.heightAnchor.constraint(equalToConstant: 50),
      ])
    }
    
    UIView.performWithoutAnimation {
      view.layoutIfNeeded()
    }
         
    editingStack.sinkState { [weak self] state in
      
      guard let self = self else { return }
      
      if let state = state._beta_map(\.loadedState) {
        
        /// Loaded
        
        self.setUpLoadedUI(state: state.primitive)
                      
        state.ifChanged(\.hasUncommitedChanges) { hasChanges in
          self.resetButton.isHidden = !hasChanges
        }
        
      } else {
        
        /// Loading
        
        self.aspectRatioButton.isEnabled = false
        self.resetButton.isEnabled = false
        self.rotateButton.isEnabled = false
        self.doneButton.isEnabled = false
             
      }
                
    }
    .store(in: &subscriptions)
           
    store.sinkState { [weak self] state in
      guard let self = self else { return }
      self.update(with: state)
    }
    .store(in: &subscriptions)
    
    editingStack.start()
  }
    
  private func setUpLoadedUI(state: EditingStack.State.Loaded) {
    
    guard hasSetupLoadedUICompleted == false else {
      return
    }
    hasSetupLoadedUICompleted = true
    
    /**
     Setup
     */
        
    self.aspectRatioButton.isEnabled = true
    self.resetButton.isEnabled = true
    self.rotateButton.isEnabled = true
    self.doneButton.isEnabled = true
    
    let control = PhotosCropAspectRatioControl(
      originalAspectRatio: .init(state.imageSize),
      localizedStrings: localizedStrings
    )
    
    control.handlers.didSelectAspectRatio = { [unowned self] aspectRatio in
      cropView.setCroppingAspectRatio(aspectRatio)
    }
    
    control.handlers.didSelectFreeform = { [unowned self] in
      cropView.setCroppingAspectRatio(nil)
    }
    
    self.aspectRatioControl = control
    
    view.addSubview(control)
        
    control&>.do {
      $0.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        $0.topAnchor.constraint(equalTo: aspectRatioControlLayoutGuide.topAnchor),
        $0.leftAnchor.constraint(equalTo: aspectRatioControlLayoutGuide.leftAnchor),
        $0.rightAnchor.constraint(equalTo: aspectRatioControlLayoutGuide.rightAnchor),
        $0.bottomAnchor.constraint(equalTo: aspectRatioControlLayoutGuide.bottomAnchor),
      ])
    }
    
    /// refresh current state
    update(with: store.state)
    
    cropView.store.sinkState { [weak self] (state) in
      
      guard let self = self else { return }
      
      state.ifChanged(\.proposedCrop?.rotation) { rotation in
        guard let rotation = rotation else { return }        
        self.aspectRatioControl?.setRotation(rotation)
      }
      
      state.ifChanged(\.preferredAspectRatio) { ratio in
        self.aspectRatioControl?.setSelected(ratio)
      }
      
    }
    .store(in: &subscriptions)
        
  }
  
  private func update(with state: Changes<State>) {
    
    let options = state.map(\.options)
    
    options.ifChanged(\.aspectRatioOptions) { value in
      switch value {
      case .fixed(let aspectRatio):
        aspectRatioButton.alpha = 0
        cropView.setCroppingAspectRatio(aspectRatio)
      case .selectable:
        aspectRatioButton.alpha = 1
        cropView.setCroppingAspectRatio(nil)
      }
    }
    
    state.ifChanged(\.isSelectingAspectRatio) { value in
      UIViewPropertyAnimator.init(duration: 0.4, dampingRatio: 1) { [self] in
        if value {
          aspectRatioControl?.alpha = 1
          aspectRatioButton.tintColor = .systemYellow
        } else {
          aspectRatioControl?.alpha = 0
          aspectRatioButton.tintColor = .systemGray
        }
      }
      .startAnimation()
    }
    
  }
  
  @objc private func handleRotateButton() {
    guard let proposedCrop = cropView.store.state.proposedCrop else {
      return
    }
    
    let rotation = proposedCrop.rotation.next()
    cropView.setRotation(rotation)
  }
  
  @objc private func handleAspectRatioButton() {
    store.commit {
      $0.isSelectingAspectRatio.toggle()
    }
  }
  
  @objc private func handleResetButton() {
    cropView.setCroppingAspectRatio(nil)
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

