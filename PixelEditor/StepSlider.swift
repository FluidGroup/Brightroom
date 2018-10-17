//
//  Slider.swift
//  PixelEditor
//
//  Created by muukii on 10/10/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

public final class StepSlider : UIControl {

  public var minStep: Int = -100 {
    didSet {
      setupValues()
    }
  }

  public var maxStep: Int = 100 {
    didSet {
      setupValues()
    }
  }

  public override var intrinsicContentSize: CGSize {
    return internalSlider.intrinsicContentSize
  }

  private let feedbackGenerator = UISelectionFeedbackGenerator()

  public var step: Int = 0 {
    didSet {
      if oldValue != step {
        setValueFromStep()

        if step == 0 {
          feedbackGenerator.selectionChanged()
          feedbackGenerator.prepare()
        }
      }

      sendActions(for: .valueChanged)
    }
  }

  private let internalSlider = _StepSlider(frame: .zero)

  public override init(frame: CGRect) {
    super.init(frame: .zero)
    setup()
    feedbackGenerator.prepare()
  }

  public required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setup() {

    internalSlider.addTarget(self, action: #selector(__didChangeValue), for: .valueChanged)

    addSubview(internalSlider)
    internalSlider.frame = bounds
    internalSlider.autoresizingMask = [.flexibleWidth, .flexibleHeight]

    setupValues()
    setValueFromStep()
  }

  private func setupValues() {

    if minStep < 0 {
      internalSlider.minimumValue = -1
    } else {
      internalSlider.minimumValue = 0
    }

    if maxStep > 0 {
      internalSlider.maximumValue = 1
    } else {
      internalSlider.maximumValue = 0
    }

    step = 0
  }

  public func transition(min: Double, max: Double) -> Double {

    if step == 0 {
      return 0
    } else {
      if step > 0 {
        return
          CalcBox.init(Double(step))
            .progress(start: Double(0), end: Double(maxStep))
            .transition(start: 0, end: max)
            .value
        
      } else {
        return
          CalcBox.init(Double(step))
            .progress(start: Double(0), end: Double(minStep))
            .transition(start: 0, end: min)
            .value
      }
    }

  }

  private let offset: CGFloat = 0.05

  @objc
  private func __didChangeValue() {

    let value = internalSlider.value

    if case -offset ... offset = CGFloat(value) {
      if self.step != 0 {
        self.step = 0
      }
      // To fix thumb
      internalSlider.value = 0
      return
    }

    let step: Int

    if value > 0 {
      step = Int(
        makeTransition(
          progress: makeProgress(value: CGFloat(value), start: offset, end: CGFloat(internalSlider.maximumValue)),
          start: 0,
          end: CGFloat(maxStep)
          )
          .rounded()
      )
    } else {
      step = Int(
        makeTransition(
          progress: makeProgress(value: CGFloat(value), start: -offset, end: CGFloat(internalSlider.minimumValue)),
          start: 0,
          end: CGFloat(minStep)
          )
          .rounded()
      )
    }

    if self.step != Int(step) {
      self.step = Int(step)
    }
  }

  private func setValueFromStep() {

    if !internalSlider.isTracking {
      if step == 0 {
        internalSlider.value = 0
      } else {
        if step > 0 {
          internalSlider.value = Float(makeTransition(progress: makeProgress(value: CGFloat(step), start: 0, end: CGFloat(maxStep)), start: offset, end: CGFloat(internalSlider.maximumValue)))
        } else {
          internalSlider.value = Float(makeTransition(progress: makeProgress(value: CGFloat(step), start: 0, end: CGFloat(minStep)), start: -offset, end: CGFloat(internalSlider.minimumValue)))
        }
      }
    }

    if step == 0 {
      internalSlider.stepLabel.text = ""
    } else {
      internalSlider.stepLabel.text = "\(step)"
    }
    internalSlider.updateStepLabel()
  }

  private func makeTransition(progress: CGFloat, start: CGFloat, end: CGFloat) -> CGFloat {
    return ((end - start) * progress) + start
  }

  private func makeProgress(value: CGFloat, start: CGFloat, end: CGFloat) -> CGFloat {
    return (value - start) / (end - start)
  }

}

final class _StepSlider: UISlider {

  enum DotLocation {
    case start
    case center
    case end
  }

  let stepLabel: UILabel = .init()

  var dotLocation: DotLocation = .center {
    didSet {
      setNeedsDisplay()
    }
  }

  override init(frame: CGRect) {

    super.init(frame: frame)
    self.setup()
  }

  required init?(coder aDecoder: NSCoder) {
    fatalError()
  }

  override func draw(_ rect: CGRect) {

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

    UIColor(white: 0, alpha: 1).setStroke()
    UIColor(white: 0, alpha: 1).setFill()

    line: do {
      let path = UIBezierPath()
      path.move(to: CGPoint.init(x: 10, y: bounds.midY))
      path.addLine(to: CGPoint.init(x: bounds.maxX - 10, y: bounds.midY))
      path.lineWidth = 1
      path.stroke()
    }

    dot: do {

      switch dotLocation {
      case .start:
        let path = UIBezierPath(ovalIn: .init(origin: .init(x: 10 - 3, y: bounds.midY - 3), size: .init(width: 6, height: 6)))
        path.fill()
      case .center:
        let path = UIBezierPath(ovalIn: .init(origin: .init(x: bounds.midX - 3, y: bounds.midY - 3), size: .init(width: 6, height: 6)))
        path.fill()
      case .end:
        let path = UIBezierPath(ovalIn: .init(origin: .init(x: bounds.maxX - 10 - 3, y: bounds.midY - 3), size: .init(width: 6, height: 6)))
        path.fill()
      }

    }

    UIGraphicsPopContext()

    context.setAlpha(0.2)
    context.draw(layer, in: bounds)
  }

  private func setup() {

    self.minimumTrackTintColor = UIColor.clear
    self.maximumTrackTintColor = UIColor.clear
    self.setThumbImage(UIImage(named: "slider_thumb", in: bundle, compatibleWith: nil), for: [])

    let label = stepLabel
    label.backgroundColor = UIColor.clear
    label.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    label.textColor = UIColor.black
    label.textAlignment = .center

    self.addSubview(label)
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesMoved(touches, with: event)
    updateStepLabel()
  }

  func updateStepLabel() {

//    var _trackImageView: UIImageView?
//
//    for imageView in self.subviews where imageView is UIImageView {
//
//      if imageView.bounds.width == imageView.bounds.height {
//        _trackImageView = imageView as? UIImageView
//      }
//    }
//
//    guard let trackImageView = _trackImageView else {
//      return
//    }
//
//    self.stepLabel.sizeToFit()
//
//    let center = CGPoint(x: trackImageView.frame.midX, y: -16)
//    self.stepLabel.center = center
  }
}
