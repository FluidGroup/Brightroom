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

/**
 It does not render anything, just giving the paths smoothified.
 */
public class SmoothPathDrawingView : PixelEditorCodeBasedView {
  
  public struct Handlers {
    public var willBeginPan: (UIBezierPath) -> Void = { _ in }
    public var panning: (UIBezierPath) -> Void = { _ in }
    public var didFinishPan: (UIBezierPath) -> Void = { _ in }
  }
  
  public var handlers = Handlers()

  private var currentBezierPath: UIBezierPath?
  private var controlPoint: Int = 0
  private var points = [CGPoint](repeating: CGPoint(), count: 5)

  // MARK: - Initializers

  public init() {
    super.init(frame: .zero)
    backgroundColor = .clear
  }

  public func willBeginPan(path: UIBezierPath) {
    handlers.willBeginPan(path)
  }

  public func panning(path: UIBezierPath) {
    handlers.panning(path)
  }

  public func didFinishPan(path: UIBezierPath) {
    handlers.didFinishPan(path)
  }

  // MARK: - Touch
  public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {

    guard let touch = touches.first else { return }

    let touchPoint = touch.location(in: self)
    currentBezierPath = UIBezierPath()

    willBeginPan(path: currentBezierPath!)

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

      currentBezierPath!.move(to: points[0])

      currentBezierPath!.addCurve(
        to: self.points[3],
        controlPoint1: points[1],
        controlPoint2: points[2])

      setNeedsDisplay()
      panning(path: currentBezierPath!)

      points[0] = points[3]
      points[1] = points[4]

      controlPoint = 1
    }

    setNeedsDisplay()
    panning(path: currentBezierPath!)
  }

  public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {

    if controlPoint == 0 {
      let touchPoint = points[0]

      currentBezierPath!.move(to: CGPoint(
        x: touchPoint.x-1.0,
        y: touchPoint.y))

      currentBezierPath!.addLine(to: CGPoint(
        x: touchPoint.x+1.0,
        y: touchPoint.y))

      setNeedsDisplay()

    } else {
      controlPoint = 0
    }

    didFinishPan(path: currentBezierPath!)
    currentBezierPath = nil
  }
}
