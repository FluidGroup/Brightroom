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

final class PhotosCropAspectRatioControl: PixelEditorCodeBasedView {
  struct State: Equatable {
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
      
      mutating func swap() {
        switch self {
        case .horizontal: self = .vertical
        case .vertical: self = .horizontal
        }
      }
    }
    
    /**
     A rectangle whose width is longer than its height
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
    
    let originalAspectRatio: PixelAspectRatio
    let originalDirection: Direction
    
    var selectedAspectRatio: PixelAspectRatio? {
      didSet {
        guard oldValue != selectedAspectRatio else { return }

        if let selectedAspectRatio {
          direction = selectedAspectRatio.height > selectedAspectRatio.width ? .vertical : .horizontal
        }
      }
    }

    var direction: Direction {
      didSet {
        if let selectedAspectRatio = selectedAspectRatio {
          if direction != selectedAspectRatio.direction {
            self.selectedAspectRatio = selectedAspectRatio.swapped()
          }
        }
      }
    }
    
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
  
  private let horizontalButton = AspectRatioDirectionButton(direction: .horizontal)
  private let verticalButton = AspectRatioDirectionButton(direction: .vertical)
  
  private let scrollView = UIScrollView()
  
  private let originalButton = AspectRatioButton()
  private let freeformButton = AspectRatioButton()
  private let aspectSquareButton = AspectRatioButton()
  
  private let store: UIStateStore<State, Never>
  private var subscriptions = Set<AnyCancellable>()
  
  private var isSupressingHandlers = false
  private let localizedStrings: PhotosCropViewController.LocalizedStrings
  
  init(
    originalAspectRatio: PixelAspectRatio,
    localizedStrings: PhotosCropViewController.LocalizedStrings
  ) {
    
    self.localizedStrings = localizedStrings
    self.store = .init(
      initialState: .init(
        originalAspectRatio: originalAspectRatio,
        originalDirection: originalAspectRatio.width > originalAspectRatio.height ? .horizontal : .vertical,
        direction: originalAspectRatio.width > originalAspectRatio.height ? .horizontal : .vertical
      )
    )
    
    super.init(frame: .zero)
    
    let directionStackView = UIStackView()&>.do {
      $0.addArrangedSubview(verticalButton)
      $0.addArrangedSubview(horizontalButton)
      $0.distribution = .equalCentering
      $0.spacing = 16
      $0.alignment = .center
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
    
    horizontalButton.onTap { [unowned self] in
      store.commit {
        $0.direction = .horizontal
      }
    }
    
    verticalButton.onTap { [unowned self] in
      store.commit {
        $0.direction = .vertical
      }
    }
    
    originalButton&>.do {
      $0.setTitle(localizedStrings.button_aspectratio_original, for: .normal)
      $0.onTap { [unowned store] in
        store.commit {
          $0.selectedAspectRatio = $0.originalAspectRatio
        }
      }
      
    }
    
    freeformButton&>.do {
      $0.setTitle(localizedStrings.button_aspectratio_freeform, for: .normal)
      $0.onTap { [unowned store] in
        store.commit {
          $0.selectedAspectRatio = nil
        }
      }
    }
    
    aspectSquareButton&>.do {
      $0.setTitle(localizedStrings.button_aspectratio_square, for: .normal)
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
        $0.topAnchor.constraint(equalTo: topAnchor, constant: 24),
        $0.rightAnchor.constraint(lessThanOrEqualTo: rightAnchor),
        $0.leftAnchor.constraint(greaterThanOrEqualTo: leftAnchor),
        $0.centerXAnchor.constraint(equalTo: centerXAnchor),
      ])
    }
    
    scrollView&>.do {
      $0.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        $0.topAnchor.constraint(equalTo: directionStackView.bottomAnchor, constant: 24),
        $0.rightAnchor.constraint(equalTo: rightAnchor),
        $0.leftAnchor.constraint(equalTo: leftAnchor),
        $0.bottomAnchor.constraint(equalTo:bottomAnchor),
      ])
      $0.contentInset = .init(top: 0, left: 24, bottom: 0, right: 24)
      $0.showsHorizontalScrollIndicator = false
    }
    
    store.sinkState { [weak self] state in
      
      guard let self = self else { return }
      
      state.ifChanged(\.selectedAspectRatio).do { selected in

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
      
      state.ifChanged(\.canSelectDirection).do { canSelectDirection in

        self.horizontalButton.isEnabled = canSelectDirection
        self.verticalButton.isEnabled = canSelectDirection
      }
            
      state.ifChanged(\.direction).do { direction in

        /// Changes display according to image's rectangle direction.
        switch direction {
        case .horizontal:
          
          self.horizontalButton.isSelected = true
          self.verticalButton.isSelected = false
          
          state.horizontalRectangleApectRatios.forEach { ratio in
            buttons[ratioValue(from: ratio)]?.setTitle("\(Int(ratio.width)):\(Int(ratio.height))", for: .normal)
          }
          
        case .vertical:
          
          self.horizontalButton.isSelected = false
          self.verticalButton.isSelected = true
          
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
    titleLabel?.font = .systemFont(ofSize: 12)
    
  }
  
  override init(frame: CGRect) {
    super.init(frame: .zero)
    
    if #available(iOS 13.0, *) {
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

private final class AspectRatioDirectionButton: UIControl {
  
  private let shapeLayer = CAShapeLayer()
  private let iconImageView = UIImageView(image: UIImage(named: "check", in: bundle, compatibleWith: nil))
  
  override var isHighlighted: Bool {
    didSet {
      guard oldValue != isHighlighted else {
        return
      }
      
      UIViewPropertyAnimator(duration: 0.4, dampingRatio: 1) { [self] in
        self.alpha = isHighlighted ? 0.4 : 1
      }
      .startAnimation()
    }
  }
  
  override var isEnabled: Bool {
    didSet {
      update()
    }
  }
  
  override var isSelected: Bool {
    didSet {
      update()
    }
  }
  
  init(direction: PhotosCropAspectRatioControl.State.Direction) {
    super.init(frame: .zero)
    
    layer.addSublayer(shapeLayer)
    iconImageView.tintColor = UIColor(white: 0, alpha: 0.8)
    
    addSubview(iconImageView)
    
    switch direction {
    case .horizontal:
      iconImageView.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        iconImageView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
        iconImageView.rightAnchor.constraint(equalTo: rightAnchor, constant: -6),
        iconImageView.leftAnchor.constraint(equalTo: leftAnchor, constant: 6),
        iconImageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
      ])
      
    case .vertical:
      iconImageView.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        iconImageView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
        iconImageView.rightAnchor.constraint(equalTo: rightAnchor, constant: -2),
        iconImageView.leftAnchor.constraint(equalTo: leftAnchor, constant: 2),
        iconImageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
      ])
      
    }
    
    update()
  }
  
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  override func layoutSubviews() {
    super.layoutSubviews()
    shapeLayer.frame = bounds
    
    let path = UIBezierPath(roundedRect: bounds, cornerRadius: 4)
    shapeLayer.path = path.cgPath
  }
  
  private func update() {
    
    guard isEnabled else {
      shapeLayer.strokeColor = UIColor(white: 0.6, alpha: 0.3).cgColor
      shapeLayer.fillColor = UIColor(white: 0, alpha: 0.3).cgColor
      iconImageView.isHidden = true
      return
    }
          
    if isSelected {
            
      shapeLayer.strokeColor = UIColor(white: 0.6, alpha: 1).cgColor
      shapeLayer.fillColor = UIColor(white: 0.6, alpha: 1).cgColor
      iconImageView.isHidden = false
      
    } else {
      shapeLayer.strokeColor = UIColor(white: 0.6, alpha: 1).cgColor
      shapeLayer.fillColor = UIColor(white: 0, alpha: 0.6).cgColor
      iconImageView.isHidden = true
      
    }
    
  }
  
}

extension PixelAspectRatio {
  var direction: PhotosCropAspectRatioControl.State.Direction {
    if height > width {
      return .vertical
    } else {
      return .horizontal
    }
  }
}

func ratioValue(from ratio: PixelAspectRatio) -> CGFloat {
  ratio.height * ratio.width
}
