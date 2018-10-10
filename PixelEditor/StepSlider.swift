//
//  Slider.swift
//  PixelEditor
//
//  Created by muukii on 10/10/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

/// -100 <-> 100
public final class StepSlider: UISlider {

  public enum AmountType {
    case plus
    case minus
    case plusMinus
  }

  public var maxPercent: Int = 100

  public var offset: Int = 3

  public var amountType: AmountType = .plusMinus {
    didSet {
      self.setupValueType()
    }
  }

  public var neutralAmount: Double = 0
  public var maximumAmount: Double = 0
  public var minimumAmount: Double = 0

  var step: Int {
    return Int(self.value)
  }

  public override var value: Float {
    didSet {
      let _offset = Float(self.offset) + 1
      if -_offset <= value && _offset >= value {

        self.value = 0
        return self.calculateAmount(0)
      } else {

        return self.calculateAmount(Double(value))
      }
    }
  }

  var amount: Double {
    get {
      return self.calculateAmount(Double(self.value))
    }
    set {

      self.value = self.calculateValue(newValue)

      DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + DispatchTimeInterval.microseconds(500)) {

        self.updateStepLabel()
      }
    }
  }

  public convenience init(maxPercent: Int) {
    self.init()
    self.maxPercent = maxPercent
  }

  public override init(frame: CGRect) {

    super.init(frame: frame)
    self.setup()
    self.setupValueType()
  }

  public required init?(coder aDecoder: NSCoder) {

    super.init(coder: aDecoder)
    self.setup()
    self.setupValueType()
  }

  public override func draw(_ rect: CGRect) {

    let stepCount = self.maxPercent

    let interval = rect.width / CGFloat(stepCount)

    do {
      let y = rect.height/2
      let bezierPath = UIBezierPath()
      bezierPath.move(to: CGPoint(x: 10, y: y))
      bezierPath.addLine(to: CGPoint(x: (interval * CGFloat(stepCount - 1)) - 10, y: y))
      UIColor(white: 0, alpha: 0.2).setStroke()
      bezierPath.stroke()
    }

    do {

      let y = rect.height/2
      let bezierPath = UIBezierPath()

      switch self.amountType {
      case .plus:
        bezierPath.move(to: CGPoint(x: 10, y: y - 6))
        bezierPath.addLine(to: CGPoint(x: 10, y: y + 6))
      case .minus:
        bezierPath.move(to: CGPoint(x: (interval * CGFloat(stepCount - 1)) - 10, y: y - 6))
        bezierPath.addLine(to: CGPoint(x: (interval * CGFloat(stepCount - 1)) - 10, y: y + 6))
      case .plusMinus:
        bezierPath.move(to: CGPoint(x: rect.width/2, y: y - 6))
        bezierPath.addLine(to: CGPoint(x: rect.width/2, y: y + 6))
      }
      UIColor(white: 0, alpha: 0.2).setStroke()
      bezierPath.stroke()
    }
  }

  private func setup() {

    self.minimumTrackTintColor = UIColor.clear
    self.maximumTrackTintColor = UIColor.clear
    self.setThumbImage(UIImage(named: "slider_thumb", in: bundle, compatibleWith: nil), for: [])

    self.rx.value.map
      { [unowned self] value -> Double in

        let _offset = Float(self.offset) + 1
        if -_offset <= value && _offset >= value {

          self.value = 0
          return self.calculateAmount(0)
        } else {

          return self.calculateAmount(Double(value))
        }
      }
      .bindTo(self.rx_amount)
      .addDisposableTo(self.disposeBag)

    self.rx_amount.subscribe(onNext: { [weak self] _ in

      self?.updateStepLabel()

    })
      .addDisposableTo(self.disposeBag)

    let label = UILabel()
    label.backgroundColor = UIColor.clear
    label.font = UIFont.systemFont(ofSize: 12)
    label.textColor = UIColor.white
    label.textAlignment = .center

    self.addSubview(label)
    self.stepLabel = label
  }

  private func calculateAmount(_ value: Double) -> Double {

    let step = self.step
    if value > 0 {
      return (((self.maximumAmount - self.neutralAmount) / Double(self.maxPercent)) * Double(step - offset)) + self.neutralAmount
    } else if value < 0 {
      return (((self.neutralAmount - self.minimumAmount) / Double(self.maxPercent)) * Double(step + offset)) + self.neutralAmount
    } else {
      return self.neutralAmount
    }
  }

  private func calculateValue(_ amount: Double) -> Float {

    var value: Double
    if amount > self.neutralAmount {

      value = (((amount - self.neutralAmount) / (self.maximumAmount - self.neutralAmount)) * Double(self.maxPercent))

    } else if amount < self.neutralAmount {

      value = -(((self.neutralAmount - amount) / (self.neutralAmount - self.minimumAmount)) * Double(self.maxPercent))

    } else {

      value = 0
    }

    let step: Int

    guard value.isInfinite == false || value.isNaN == false else {
      return 0
    }

    if value > 0 {
      step = Int(value + 0.5) + offset
    } else if value < 0 {
      step = Int(value - 0.5) - offset
    } else {
      step = Int(value)
    }

    return Float(step)
  }

  private func setupValueType() {

    switch self.amountType {
    case .plus:
      maximumValue = Float(maxPercent + offset)
      minimumValue = 0
    case .minus:
      maximumValue = 0
      minimumValue = -Float(maxPercent + offset)
    case .plusMinus:
      maximumValue = Float(maxPercent + offset)
      minimumValue = -Float(maxPercent + offset)
    }
  }

  private weak var stepLabel: UILabel?

  private func updateStepLabel() {

    var _trackImageView: UIImageView?

    for imageView in self.subviews where imageView is UIImageView {

      if imageView.bounds.width == imageView.bounds.height {
        _trackImageView = imageView as? UIImageView
      }
    }

    guard let trackImageView = _trackImageView else {
      return
    }

    let _offset = Float(self.offset) + 1
    if -_offset <= self.value && _offset >= self.value {
      self.stepLabel?.isHidden = true
    } else {
      self.stepLabel?.isHidden = false
    }

    if self.step > 0 {
      self.stepLabel?.text = String(self.step - self.offset)
    } else {
      self.stepLabel?.text = String(self.step + self.offset)
    }

    self.stepLabel?.sizeToFit()

    let center = CGPoint(x: trackImageView.frame.midX, y: -10)
    self.stepLabel?.center = center
  }
}
