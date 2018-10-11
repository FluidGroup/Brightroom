//
//  DryDrawingView.swift
//  PixelEditor
//
//  Created by muukii on 10/12/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import UIKit

public class DryDrawingView : UIView {

  private var bezierPath: UIBezierPath = UIBezierPath()
  private var controlPoint: Int = 0
  private var points = [CGPoint](repeating: CGPoint(), count: 5)

  // MARK: - Initializers

  public init() {
    super.init(frame: .zero)
    backgroundColor = .clear
  }

  public required init?(coder aDecoder: NSCoder) {
    fatalError()
  }

  public func willBeginPan(path: UIBezierPath) {

  }

  public func panning(path: UIBezierPath) {

  }

  public func didFinishPan(path: UIBezierPath) {

  }

  // MARK: - Touch
  public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {

    guard let touch = touches.first else { return }

    let touchPoint = touch.location(in: self)
    bezierPath = UIBezierPath()

    willBeginPan(path: bezierPath)

    controlPoint = 0
    points[0] = touchPoint
  }

  public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {

    guard let touch = touches.first else { return }
    let touchPoint = touch.location(in: self)

    controlPoint += 1
    points[controlPoint]  = touchPoint

    if controlPoint == 4 {

      points[3] = CGPoint(
        x: (points[2].x + points[4].x)/2.0,
        y: (points[2].y + points[4].y)/2.0)

      bezierPath.move(to: points[0])

      bezierPath.addCurve(
        to: self.points[3],
        controlPoint1: points[1],
        controlPoint2: points[2])

      setNeedsDisplay()
      panning(path: bezierPath)

      points[0] = points[3]
      points[1] = points[4]

      controlPoint = 1
    }

    setNeedsDisplay()
    panning(path: bezierPath)
  }

  public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {

    if controlPoint == 0 {
      let touchPoint = points[0]

      bezierPath.move(to: CGPoint(
        x: touchPoint.x-1.0,
        y: touchPoint.y))

      bezierPath.addLine(to: CGPoint(
        x: touchPoint.x+1.0,
        y: touchPoint.y))

      setNeedsDisplay()

    } else {
      controlPoint = 0
    }

    didFinishPan(path: bezierPath)
  }
}
