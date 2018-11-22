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

open class ColorControlViewBase : ControlBase {

  public required override init(context: PixelEditContext) {
    super.init(context: context)
  }
}

open class ColorControlView : ColorControlViewBase {
  
  public enum DisplayType {
    case shadows
    case highlights
  }
  
  public var displayType: DisplayType = .shadows {
    didSet {
      guard oldValue != displayType else { return }
      set(displayType: displayType)
    }
  }
  
  var regularConstraints: [NSLayoutConstraint] = []
  
  var compactConstraints: [NSLayoutConstraint] = []
  
  private let containerView = UIView()
  
  public var shadowsColorControl:ColorShadowsControlBase!
  
  public var highlightsColorControl:ColorHighlightsControlBase!
  
  public let shadowsButton = UIButton(type: .system)
  
  public let highlightsButton = UIButton(type: .system)

  private let navigationView = NavigationView()
  
  open override func setup() {
    super.setup()
    
    backgroundColor = Style.default.control.backgroundColor
    
    shadowsColorControl = ColorShadowsControl(context: context)
    highlightsColorControl = ColorHighlightsControl(context: context)

    navigationView.didTapCancelButton = { [weak self] in
      self?.context.action(.revert)
      self?.pop(animated: true)
    }

    navigationView.didTapDoneButton = { [weak self] in
      self?.context.action(.commit)
      self?.pop(animated: true)
    }
    
    layout: do {
      let stackView = UIStackView(arrangedSubviews: [shadowsButton, highlightsButton])
      stackView.axis = .horizontal
      stackView.distribution = .fillEqually
      
      
      addSubview(stackView)
      addSubview(containerView)
      addSubview(navigationView)
      
      stackView.translatesAutoresizingMaskIntoConstraints = false
      containerView.translatesAutoresizingMaskIntoConstraints = false
      navigationView.translatesAutoresizingMaskIntoConstraints = false
      
      
      NSLayoutConstraint.activate([
        stackView.topAnchor.constraint(equalTo: stackView.superview!.topAnchor),
        stackView.leftAnchor.constraint(equalTo: stackView.superview!.leftAnchor),
        stackView.rightAnchor.constraint(equalTo: stackView.superview!.rightAnchor),
        
        containerView.topAnchor.constraint(equalTo: stackView.bottomAnchor),
        containerView.rightAnchor.constraint(equalTo: containerView.superview!.rightAnchor),
        containerView.leftAnchor.constraint(equalTo: containerView.superview!.leftAnchor),
        
        navigationView.topAnchor.constraint(equalTo: containerView.bottomAnchor),
        navigationView.rightAnchor.constraint(equalTo: navigationView.superview!.rightAnchor),
        navigationView.leftAnchor.constraint(equalTo: navigationView.superview!.leftAnchor),
        navigationView.bottomAnchor.constraint(equalTo: navigationView.superview!.bottomAnchor),
      ])
      
      regularConstraints = [stackView.heightAnchor.constraint(equalToConstant: 50)]
      compactConstraints = [stackView.heightAnchor.constraint(equalToConstant: 20)]
      
      activateCurrentConstraints()
    }
    
    body: do {
      shadowsButton.backgroundColor = UIColor.black.withAlphaComponent(0.1)
      highlightsButton.backgroundColor = UIColor.black.withAlphaComponent(0.1)
      
      shadowsButton.setTitle(L10n.editShadows, for: .normal)
      highlightsButton.setTitle(L10n.editHighlights, for: .normal)
      
      shadowsButton.tintColor = .clear
      highlightsButton.tintColor = .clear
      
      shadowsButton.setTitleColor(UIColor.black.withAlphaComponent(0.5), for: .normal)
      highlightsButton.setTitleColor(UIColor.black.withAlphaComponent(0.5), for: .normal)
      
      shadowsButton.setTitleColor(.black, for: .selected)
      highlightsButton.setTitleColor(.black, for: .selected)
      
      shadowsButton.titleLabel!.font = UIFont.boldSystemFont(ofSize: 17)
      highlightsButton.titleLabel!.font = UIFont.boldSystemFont(ofSize: 17)
      
      shadowsButton.addTarget(self, action: #selector(didTapFilterButton), for: .touchUpInside)
      highlightsButton.addTarget(self, action: #selector(didTapEditButton), for: .touchUpInside)
    }
  }
  
  private func activateCurrentConstraints() {
    NSLayoutConstraint.deactivate(self.compactConstraints + self.regularConstraints)
    
    if self.traitCollection.verticalSizeClass == .regular {
      NSLayoutConstraint.activate(self.regularConstraints)
    }
    else {
      NSLayoutConstraint.activate(self.compactConstraints)
    }
  }
  
  open override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    activateCurrentConstraints()
  }
  
  override open func didMoveToSuperview() {
    super.didMoveToSuperview()
    
    if superview != nil {
      set(displayType: displayType)
    }
  }
  
  @objc
  private func didTapFilterButton() {
    displayType = .shadows
  }
  
  @objc
  private func didTapEditButton() {
    displayType = .highlights
  }
  
  private func set(displayType: DisplayType) {

    containerView.subviews.forEach { $0.removeFromSuperview() }

    shadowsButton.isSelected = false
    highlightsButton.isSelected = false

    
    switch displayType {
    case .shadows:

      shadowsColorControl.frame = containerView.bounds
      shadowsColorControl.autoresizingMask = [.flexibleWidth, .flexibleHeight]

      containerView.addSubview(shadowsColorControl)
      subscribeChangedEdit(to: shadowsColorControl)

      shadowsButton.isSelected = true

    case .highlights:

      highlightsColorControl.frame = containerView.bounds
      highlightsColorControl.autoresizingMask = [.flexibleWidth, .flexibleHeight]

      containerView.addSubview(highlightsColorControl)
      subscribeChangedEdit(to: highlightsColorControl)

      highlightsButton.isSelected = true
    }
  }
}
