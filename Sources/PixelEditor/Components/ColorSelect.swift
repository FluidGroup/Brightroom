//
//  ColorSelect.swift
//  PixelEngine
//
//  Created by Danny on 18.11.18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation
import UIKit

public class ColorSelectButtons : UIControl {
  
  public var colors: [ColorName] = [] {
    didSet {
      setupButtons()
    }
  }
  
  private let contentView = UIStackView(frame: .zero)
  
  public override var intrinsicContentSize: CGSize {
    return contentView.intrinsicContentSize
  }
  
  public private(set) var step: Int = 0 {
    didSet {
      if oldValue != step {
      }
      
      sendActions(for: .valueChanged)
    }
  }
  
  public override init(frame: CGRect) {
    super.init(frame: .zero)
    setup()
  }
  
  public required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  private func setup() {
    
    addSubview(contentView)
    contentView.frame = bounds
    contentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    contentView.axis = .horizontal
    contentView.distribution = .fillEqually
    
    setupButtons()
  }
  
  func setupButtons() {
    for view in contentView.arrangedSubviews {
      contentView.removeArrangedSubview(view)
    }
    
    for color in colors {
      let button = ColorSelectItem(type: .system)
      button.color = UIColor(hex: color)
      button.addTarget(self, action: #selector(__didChangeValue(_:)), for: .touchUpInside)
      contentView.addArrangedSubview(button)
    }
  }
  
  public func set(value: Int) {
    
    if let sender = contentView.arrangedSubviews[value] as? ColorSelectItem {
      __didChangeValue(sender)
    }
  }
  
  @objc
  private func __didChangeValue(_ sender: ColorSelectItem) {
    var step: Int = 0
    
    for (key, view) in contentView.arrangedSubviews.enumerated() {
      guard let colorButton = view as? ColorSelectItem else {
        continue
      }
      
      if colorButton == sender {
        colorButton.isSelected = true
        step = key
      } else {
        colorButton.isSelected = false
      }
    }
    
    
    self.step = Int(step)
  }
  
}

public class ColorSelectItem: UIButton {
  var color: UIColor? = nil {
    didSet {
      setNeedsDisplay()
    }
  }
  
  override public func draw(_ rect: CGRect) {
    
    guard let context = UIGraphicsGetCurrentContext() else {
      return
    }
    
    let scale = contentScaleFactor
    
    guard
      let layer = CGLayer(context, size: CGSize(width: bounds.size.width * scale, height: bounds.size.height * scale), auxiliaryInfo: nil),
      let layerContext = layer.context
      else {
        return
    }
    
    UIGraphicsPushContext(layerContext)
    
    layerContext.scaleBy(x: scale, y: scale)
    
    if let color = self.color {
      color.setStroke()
      color.setFill()
    }
    
    line: do {
      let path = UIBezierPath(ovalIn: .init(origin: .init(x: bounds.midX - 10 + 3, y: bounds.midY - 10 + 3), size: .init(width: 20, height: 20)))
      path.lineWidth = 2
      path.stroke()
    }
    
    dot: do {
      let path = UIBezierPath(ovalIn: .init(origin: .init(x: bounds.midX, y: bounds.midY), size: .init(width: 6, height: 6)))
      path.fill()
    }
    
    UIGraphicsPopContext()
    
    context.draw(layer, in: bounds)
  }
}

