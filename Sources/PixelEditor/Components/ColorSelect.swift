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
  
  public var colors: [UIColor] = [] {
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
    
    for (key, color) in colors.enumerated() {
      let button = ColorSelectItem(type: .custom)
      button.color = color
      button.isSelected = key == step
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

class CoreCircle: CAShapeLayer {
  var color: CGColor? = nil {
    didSet {
      setNeedsDisplay()
    }
  }
  
  var progress: CGFloat = 1 {
    didSet {
      setNeedsDisplay()
    }
  }
  
  override init() {
    super.init()
    contentsScale = UIScreen.main.scale
  }
  
  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  private func progressInterpolated() -> CGFloat {
    return max(min(progress, 1), 0) + 1
  }
  
  override func draw(in context: CGContext) {
    if let color = color {
      context.setStrokeColor(color)
      context.setFillColor(color)
    }

    let newSize = CGSize(width: bounds.width / 2.5 * progressInterpolated(), height: bounds.height / 2.5 * progressInterpolated())
    let newPosition = CGPoint(x: bounds.midX - newSize.width/2, y: bounds.midY - newSize.height/2)
    let path = UIBezierPath(ovalIn: CGRect(origin: newPosition, size: newSize))
    context.addPath(path.cgPath)
    context.fillPath()
  }
}

class BorderCircle: CAShapeLayer {
  var color: CGColor? = nil {
    didSet {
      setNeedsDisplay()
    }
  }
  
  var progress: CGFloat = 1 {
    didSet {
      setNeedsDisplay()
    }
  }
  
  override init() {
    super.init()
    contentsScale = UIScreen.main.scale
  }
  
  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  private func progressInterpolated() -> CGFloat {
    return max(min(progress, 1), 0) + 1
  }
  
  override func draw(in context: CGContext) {
    if let color = self.color {
      context.setStrokeColor(color)
      context.setFillColor(color)
    }

    let newSize = CGSize(width: bounds.width * progressInterpolated() - 2, height: bounds.height * progressInterpolated() - 2)
    let newPosition = CGPoint(x: bounds.midX - newSize.width/2, y: bounds.midY - newSize.height/2)
    let path = UIBezierPath(ovalIn: CGRect(origin: newPosition, size: newSize))
    path.lineWidth = 2
    
    context.addPath(path.cgPath)
    context.strokePath()
  }
}

class StrikeThrough: CAShapeLayer {
  
  override init() {
    super.init()
    contentsScale = UIScreen.main.scale
    fillRule = .evenOdd
    fillColor = UIColor.black.cgColor
  }
  
  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  override func draw(in context: CGContext) {
    let rectanglePath = UIBezierPath()
    rectanglePath.move(to: CGPoint(x: 0, y: bounds.height))
    rectanglePath.addLine(to: CGPoint(x: 0, y: bounds.height + 2))
    rectanglePath.addLine(to: CGPoint(x: bounds.width - 2, y: 0))
    rectanglePath.addLine(to: CGPoint(x: bounds.width - 3, y: 0))
    rectanglePath.addLine(to: CGPoint(x: 0, y: bounds.height))
    rectanglePath.close()
    
    let path = CGMutablePath()
    path.addPath(rectanglePath.cgPath)
    path.addRect(CGRect(x: 0, y: 0, width: 20, height: 20))
    
    self.path = path
  }
}

public class ColorSelectItem: UIButton {
  var color: UIColor? = nil {
    didSet {
      coreCircleLayer.color = color != .clear ? color?.cgColor : UIColor.black.cgColor
      borderCircleLayer.color = color != .clear ? color?.cgColor : UIColor.black.cgColor
    }
  }
  
  public override var isSelected: Bool {
    didSet {
      coreCircleLayer.progress = !isSelected ? 0 : 1
      borderCircleLayer.progress = !isSelected ? 0 : 1
      coreCircleLayer.mask = isSelected && color == .clear ? strikeThroughLayer : nil
    }
  }
  
  public override init(frame: CGRect) {
    super.init(frame: .zero)
    setup()
  }
  
  public required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  public override func awakeFromNib() {
    super.awakeFromNib()
    setup()
  }
  
  var coreCircleLayer: CoreCircle!
  var borderCircleLayer: BorderCircle!
  var strikeThroughLayer: StrikeThrough!
  
  func setup() {
    coreCircleLayer = CoreCircle()
    borderCircleLayer = BorderCircle()
    strikeThroughLayer = StrikeThrough()
    
    layer.addSublayer(coreCircleLayer)
    layer.addSublayer(borderCircleLayer)
    coreCircleLayer.mask = strikeThroughLayer
  }
  
  public override func layoutSubviews() {
    let newSize = CGSize(width: 20, height: 20)
    let newPosition = CGPoint(x: bounds.width/2 - newSize.width/2, y: center.y - newSize.height/2)
    
    borderCircleLayer.frame = CGRect(origin: newPosition, size: newSize)
    coreCircleLayer.frame = CGRect(origin: newPosition, size: newSize)
    strikeThroughLayer.frame = coreCircleLayer.bounds
    strikeThroughLayer.setNeedsDisplay()
  }
}
