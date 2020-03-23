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
import Foundation
import PixelEngine

open class MaskControlBase : ControlBase {

}

open class MaskControl : MaskControlBase {

  private let contentView = UIView()
  private let navigationView = NavigationView()
  
  private let clearButton = UIButton(type: .system)
  private let slider = StepSlider()
  private let sizeIndicator = UIView()

  open override func setup() {
    super.setup()

    backgroundColor = Style.default.control.backgroundColor
    
    base: do {
      
      addSubview(contentView)
      addSubview(navigationView)
      
      contentView.translatesAutoresizingMaskIntoConstraints = false
      navigationView.translatesAutoresizingMaskIntoConstraints = false
      
      NSLayoutConstraint.activate([
        
        contentView.topAnchor.constraint(equalTo: contentView.superview!.topAnchor),
        contentView.rightAnchor.constraint(equalTo: contentView.superview!.rightAnchor),
        contentView.leftAnchor.constraint(equalTo: contentView.superview!.leftAnchor),
        
        navigationView.topAnchor.constraint(equalTo: contentView.bottomAnchor),
        navigationView.rightAnchor.constraint(equalTo: navigationView.superview!.rightAnchor),
        navigationView.leftAnchor.constraint(equalTo: navigationView.superview!.leftAnchor),
        navigationView.bottomAnchor.constraint(equalTo: navigationView.superview!.bottomAnchor),
        ])
      
    }
    
    clearButton: do {
      
      contentView.addSubview(clearButton)
      clearButton.translatesAutoresizingMaskIntoConstraints = false
      
      NSLayoutConstraint.activate([
        clearButton.centerXAnchor.constraint(equalTo: clearButton.superview!.centerXAnchor),
        clearButton.topAnchor.constraint(equalTo: clearButton.superview!.topAnchor, constant: 16),        
        ])
      
      clearButton.addTarget(self, action: #selector(didTapRemoveAllButton), for: .touchUpInside)
      clearButton.setTitle(L10n.clear, for: .normal)
      clearButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 17)
      
    }

    sizeSlider: do {
      slider.set(value: 0, min: -0.5, max: 0.5)
      slider.mode = .plusAndMinus
      slider.isStepLabelHidden = true
      valueChanged()
      let smallLabel = UILabel()
      let largeLabel = UILabel()

      smallLabel.translatesAutoresizingMaskIntoConstraints = false
      largeLabel.translatesAutoresizingMaskIntoConstraints = false
      slider.translatesAutoresizingMaskIntoConstraints = false

      smallLabel.text = L10n.brushSizeSmall
      smallLabel.textColor = .black
      largeLabel.textColor = .black
      largeLabel.text = L10n.brushSizeLarge

      smallLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
      largeLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

      contentView.addSubview(smallLabel)
      contentView.addSubview(largeLabel)
      contentView.addSubview(slider)
      NSLayoutConstraint.activate([
        smallLabel.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.layoutMarginsGuide.leadingAnchor),
        slider.leadingAnchor.constraint(equalTo: smallLabel.trailingAnchor, constant: 8),
        largeLabel.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 8),
        slider.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        largeLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.layoutMarginsGuide.trailingAnchor),
        smallLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        largeLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        slider.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
        slider.widthAnchor.constraint(equalTo: contentView.superview!.widthAnchor, multiplier: 2.0/3.0)
      ])
      slider.addTarget(self, action: #selector(valueChanged), for: .valueChanged)
    }

    sizeIndicator: do {
      contentView.addSubview(sizeIndicator)
      sizeIndicator.translatesAutoresizingMaskIntoConstraints = false
      sizeIndicator.layer.cornerRadius = 50 / 2
      sizeIndicator.clipsToBounds = false
      sizeIndicator.backgroundColor = .white
      sizeIndicator.layer.borderColor = UIColor.black.cgColor
      sizeIndicator.layer.borderWidth = 1
      NSLayoutConstraint.activate([
        sizeIndicator.widthAnchor.constraint(equalToConstant: 50),
        sizeIndicator.heightAnchor.constraint(equalToConstant: 50),
        sizeIndicator.topAnchor.constraint(equalTo: slider.bottomAnchor, constant: 8),
        sizeIndicator.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      ])
    }


    navigationView.didTapCancelButton = { [weak self] in

      self?.pop(animated: true)
      self?.context.action(.endMasking(save: false))
    }

    navigationView.didTapDoneButton = { [weak self] in

      self?.pop(animated: true)
      self?.context.action(.endMasking(save: true))
    }

  }

  open override func didMoveToSuperview() {
    super.didMoveToSuperview()

    if superview != nil {
      context.action(.setMode(.masking))
    } else {
      context.action(.setMode(.preview))
    }
  }

  @objc
  private func valueChanged() {
    let position = CGFloat(slider.transition(min: -0.5, max: 0.5) + 0.5)
    let min = CGFloat(5)
    let max = CGFloat(50)
    let size = (min + position * (max - min)).rounded()

    sizeIndicator.transform = .init(scaleX: size / max, y: size / max)
    context.action(.setMaskingBrushSize(size: size))
  }

  @objc
  private func didTapRemoveAllButton() {
    
    context.action(.removeAllMasking)
  }
}
