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

struct Progress {

  var fractionCompleted: Double

  init(_ fractionCompleted: Double) {
    self.fractionCompleted = fractionCompleted
  }
}

struct CalcBox<T> {

  var value: T

  init(_ value: T) {
    self.value = value
  }
}

extension CalcBox where T == Double {

  func clip(min: Double, max: Double) -> CalcBox<Double> {
    return .init(Swift.max(Swift.min(value, max), min))
  }

  func progress(start: Double, end: Double) -> CalcBox<Progress> {
    return .init(Progress.init((value - start) / (end - start)))
  }
}

extension CalcBox where T == Progress {

  func reverse() -> CalcBox<Progress> {
    return .init(Progress(1 - value.fractionCompleted))
  }

  func transition(start: Double, end: Double) -> CalcBox<Double> {
    return .init(((end - start) * value.fractionCompleted) + start)
  }

  func clip(min: Double, max: Double) -> CalcBox<Progress> {
    return .init(Progress(Swift.max(Swift.min(value.fractionCompleted, max), min)))
  }
}

extension CalcBox where T == CGPoint {

  func vector() -> CalcBox<CGVector> {
    return .init(CGVector(dx: value.x, dy: value.y))
  }

  func distance(from: CGPoint) -> CalcBox<CGFloat> {
    return .init(sqrt(pow(value.x - from.x, 2) + pow(value.y - from.y, 2)))
  }

  func distance(to: CGPoint) -> CalcBox<CGFloat> {
    return .init(sqrt(pow(to.x - value.x, 2) + pow(to.y - value.y, 2)))
  }
}

extension CalcBox where T == CGVector {
  func magnitude() -> CGFloat {
    return sqrt(pow(value.dx, 2) + pow(value.dy, 2))
  }
}
