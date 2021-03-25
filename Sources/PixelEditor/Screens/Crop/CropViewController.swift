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
    public var didFinish: (CropViewController) -> Void = { _ in }
    public var didCancel: (CropViewController) -> Void = { _ in }
  }
  
  private struct State: Equatable {
    var isSelectingAspectRatio = false
    var options: Options
  }
  
  // MARK: - Properties
  
  private let store: UIStateStore<State, Never>
  
  private let cropView: CropView
  private var aspectRatioControl: AspectRatioControl?
  
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
  
  // MARK: - Initializers
      
  public init(editingStack: EditingStack, options: Options = .init()) {
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
    options: Options = .init()
  ) {
    self.init(
      editingStack: .init(
        imageProvider: imageProvider,
        previewMaxPixelSize: UIScreen.main.bounds.height * UIScreen.main.scale
      ),
      options: options
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
  public func renderImage(resolution: ImageRenderer.Resolution, completion: @escaping (UIImage?) -> Void) {
    editingStack.makeRenderer()?.render(resolution: resolution, completion: completion) ?? completion(nil)
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
      $0.setTitle("RESET", for: .normal)
      $0.titleLabel?.font = UIFont.systemFont(ofSize: 15)
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
      // FIXME: Localize
      $0.setTitle("Cancel", for: .normal)
      $0.titleLabel?.font = UIFont.systemFont(ofSize: 17)
      $0.setTitleColor(UIColor.white, for: .normal)
      $0.addTarget(self, action: #selector(handleCancelButton), for: .touchUpInside)
    }
        
    doneButton&>.do {
      // FIXME: Localize
      $0.setTitle("Done", for: .normal)
      $0.titleLabel?.font = UIFont.systemFont(ofSize: 17)
      $0.setTitleColor(UIColor.systemYellow, for: .normal)
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
    
    let control = AspectRatioControl(originalAspectRatio: .init(state.imageSize))
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
      /**
       +----+
       |    |
       |    |
       |    |
       |    |
       |    |
       |    |
       +----+
       */
      case vertical
      /**
       +---------------+
       |               |
       |               |
       +---------------+
       */
      case horizontal
    }
    
    /**
     +---------------+
     |               |
     |               |
     +---------------+
     */
    let horizontalRectangleApectRatios: [PixelAspectRatio] = [
      .init(width: 16, height: 9),
      .init(width: 10, height: 8),
      .init(width: 7, height: 5),
      .init(width: 4, height: 3),
      .init(width: 5, height: 3),
      .init(width: 3, height: 2),
    ]
    
    var originalAspectRatio: PixelAspectRatio
    
    var selectedAspectRatio: PixelAspectRatio?
    
    var direction: Direction
        
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
  
  struct Handlers {
    
    var didSelectAspectRatio: (PixelAspectRatio) -> Void = { _ in }
    var didSelectFreeform: () -> Void = {}
    
  }
  
  var handlers: Handlers = .init()
  
  private let horizontalButton = UIButton(type: .system)
  private let verticalButton = UIButton(type: .system)
  
  private let scrollView = UIScrollView()
  
  private let originalButton = AspectRatioButton()
  private let freeformButton = AspectRatioButton()
  private let aspectSquareButton = AspectRatioButton()
  
  private let store: UIStateStore<State, Never>
  private var subscriptions = Set<VergeAnyCancellable>()
  
  init(originalAspectRatio: PixelAspectRatio) {
    store = .init(
      initialState: .init(
        originalAspectRatio: originalAspectRatio,
        direction: originalAspectRatio.width > originalAspectRatio.height ? .horizontal : .vertical
      )
    )
    
    super.init(frame: .zero)
    
    let directionStackView = UIStackView()&>.do {
      $0.addArrangedSubview(horizontalButton)
      $0.addArrangedSubview(verticalButton)
    }
    
    var buttons: [CGFloat: UIButton] = [:]
    
    buttons[ratioValue(from: store.state.originalAspectRatio)] = originalButton
    buttons[ratioValue(from: .square)] = aspectSquareButton
    
    let itemsStackView = UIStackView()&>.do { stackView in
      
      stackView.spacing = 12
      
      [
        originalButton,
        freeformButton,
        aspectSquareButton,
      ]
      .forEach {
        stackView.addArrangedSubview($0)
      }
      
      store.state.horizontalRectangleApectRatios.forEach { ratio in
        
        let button = AspectRatioButton()
        
        stackView.addArrangedSubview(button)
        
        button.onTap { [unowned store] in
          store.commit {
            
            switch $0.direction {
            case .horizontal:
              
              $0.selectedAspectRatio = ratio
              
            case .vertical:
              
              $0.selectedAspectRatio = ratio.swapped()
            }
            
          }
        }
        
        buttons[ratioValue(from: ratio)] = button
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
      
      state.ifChanged(\.selectedAspectRatio) { selected in
        
        guard let selected = selected else {
          // Freeform
          
          buttons.forEach {
            $0.value.isSelected = false
          }
          
          self.freeformButton.isSelected = true
          
          self.handlers.didSelectFreeform()
          
          return
        }
        
        self.freeformButton.isSelected = false
        
        buttons.forEach {
          if $0.key == ratioValue(from: selected) {
            $0.value.isSelected = true
          } else {
            $0.value.isSelected = false
          }
        }
           
        self.handlers.didSelectAspectRatio(selected)
              
      }
            
      state.ifChanged(\.canSelectDirection) { canSelectDirection in
        
        self.horizontalButton.isEnabled = canSelectDirection
        self.verticalButton.isEnabled = canSelectDirection
      }
      
      state.ifChanged(\.direction) { direction in
        
        /// Changes display according to image's rectangle direction.
        switch direction {
        case .horizontal:
          
          state.horizontalRectangleApectRatios.forEach { ratio in
            buttons[ratioValue(from: ratio)]?.setTitle("\(Int(ratio.width)):\(Int(ratio.height))", for: .normal)
          }
          
        case .vertical:
          
          state.horizontalRectangleApectRatios.forEach { ratio in
            buttons[ratioValue(from: ratio)]?.setTitle("\(Int(ratio.height)):\(Int(ratio.width))", for: .normal)
          }
        }
      }
    }
    .store(in: &subscriptions)
  }
  
  func setSelected(_ aspectRatio: PixelAspectRatio?) {
    
    guard let fixed = aspectRatio else {
      store.commit {
        if $0.selectedAspectRatio != nil {
          $0.selectedAspectRatio = nil
        }
      }
      return
    }

    store.commit {
      if $0.selectedAspectRatio != fixed {
        $0.selectedAspectRatio = fixed
      }
    }
  }
}

private final class AspectRatioButton: UIButton {
  
  private let backdropView = UIView()
  
  override var isSelected: Bool {
    didSet {
      setNeedsLayout()
    }
  }
  
  convenience init() {
    self.init(frame: .zero)
        
    setTitleColor(.init(white: 1, alpha: 0.5), for: .normal)
    setTitleColor(.white, for: .selected)
    titleLabel?.font = .systemFont(ofSize: 14)

  }
  
  override init(frame: CGRect) {
    super.init(frame: .zero)
       
    if #available(iOSApplicationExtension 13.0, *) {
      backdropView.layer.cornerCurve = .continuous
    } else {
      // Fallback on earlier versions
    }
    
    backdropView.backgroundColor = .init(white: 1, alpha: 0.5)
    
    titleEdgeInsets = .init(top: -2, left: 6, bottom: -2, right: 6)
  }
  
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  override func layoutSubviews() {
    super.layoutSubviews()
    
    insertSubview(backdropView, at: 0)
    backdropView.frame = bounds
    backdropView.layer.cornerRadius = bounds.height / 2
  
    backdropView.isHidden = !isSelected
  }
  
  override var intrinsicContentSize: CGSize {
    let originalContentSize = super.intrinsicContentSize
    let adjustedWidth = originalContentSize.width + titleEdgeInsets.left + titleEdgeInsets.right
    let adjustedHeight = originalContentSize.height + titleEdgeInsets.top + titleEdgeInsets.bottom
    return CGSize(width: adjustedWidth, height: adjustedHeight)
  }
  
}

func ratioValue(from ratio: PixelAspectRatio) -> CGFloat {
  ratio.height * ratio.width
}
