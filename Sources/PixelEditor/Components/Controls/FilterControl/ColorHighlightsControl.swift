//
//  ColorHighlightsControl.swift
//  PixelEngine
//
//  Created by Danny on 19.11.18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

import PixelEngine

open class ColorHighlightsControlBase : FilterControlBase {
  
  public required init(context: PixelEditContext) {
    super.init(context: context)
  }
}

open class ColorHighlightsControl : ColorHighlightsControlBase {
  
  open override var title: String {
    return L10n.editHighlights
  }
  
  public let colorButtons = ColorSelectButtons(frame: .zero)
  private let colors = [UIColor.clear] + FilterHighlightShadowTint.HighlightTintColors.allCases.map { UIColor(hex: $0.rawValue) }
  
  open override func setup() {
    super.setup()
    
    backgroundColor = Style.default.control.backgroundColor
    
    layout: do {
      addSubview(colorButtons)
      
      colorButtons.translatesAutoresizingMaskIntoConstraints = false
      
      NSLayoutConstraint.activate([
        colorButtons.rightAnchor.constraint(equalTo: colorButtons.superview!.rightAnchor),
        colorButtons.leftAnchor.constraint(equalTo: colorButtons.superview!.leftAnchor),
        colorButtons.centerYAnchor.constraint(equalTo: colorButtons.superview!.centerYAnchor),
        colorButtons.heightAnchor.constraint(equalToConstant: 100)
        ])
      
      colorButtons.addTarget(self, action: #selector(valueChanged), for: .valueChanged)
    }
    
    body: do {
      colorButtons.colors = colors
    }
  }
  
  open override func didReceiveCurrentEdit(_ edit: EditingStack.Edit) {
    let valueOptional = colors.map { CIColor(color: $0) }.index(where: { $0 == edit.filters.color?.highlightColor })
    
    if let value = valueOptional, value != colorButtons.step {
      colorButtons.set(value: value)
    }
  }
  
  open override func didMoveToSuperview() {
    super.didMoveToSuperview()
    
    if superview != nil {
      valueChanged()
    }
  }
  
  @objc
  private func valueChanged() {
    let value = colorButtons.step
    
    guard value != 0 else {
      context.action(.setFilter({ $0.color = nil }))
      return
    }
    var f = FilterHighlightShadowTint()
    f.highlightColor = CIColor(color: colors[value])
    context.action(.setFilter({ $0.color = f }))
  }
}
