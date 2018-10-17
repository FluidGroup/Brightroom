//
//  CalcBox.swift
//  PixelEditor
//
//  Created by muukii on 10/17/18.
//  Copyright © 2018 muukii. All rights reserved.
//

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
