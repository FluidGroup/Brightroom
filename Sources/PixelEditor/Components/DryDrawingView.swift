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
