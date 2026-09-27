//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
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

import SwiftUI

import BrightroomParametric

extension QuarterTurn {

  /// The angle the canvas rotates its UIKit views by to show this turn.
  ///
  /// UIKit is y-down, the convention of the raw value, so the canvas turns
  /// the same way on screen as the rendered output.
  var angle: Angle {
    .degrees(Double(rawValue))
  }

  /// The turn after one more counterclockwise quarter turn: what the built-in
  /// rotate button does.
  func turnedCounterclockwise() -> QuarterTurn {
    switch self {
    case .zero: return .counterclockwise
    case .counterclockwise: return .halfTurn
    case .halfTurn: return .clockwise
    case .clockwise: return .zero
    }
  }
}
