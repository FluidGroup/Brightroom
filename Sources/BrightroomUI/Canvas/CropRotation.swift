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

import CoreGraphics
import SwiftUI

import BrightroomParametric

/// The quarter-turn rotation of a crop in BrightroomUI's working vocabulary.
///
/// A faithful port of the former `EditingCrop.Rotation` (the UI continues to use
/// `.angle_0/.angle_90/…`, `.angle`, `.transform`, `.next()`), plus a bridge to
/// and from the engine's dependency-free `QuarterTurn`.
public enum CropRotation: Equatable, CaseIterable, Sendable {
  /// 0 degree - default
  case angle_0

  /// 90 degree
  case angle_90

  /// 180 degree
  case angle_180

  /// 270 degree
  case angle_270

  public var angle: Angle {
    switch self {
    case .angle_0:
      return .degrees(0)
    case .angle_90:
      return .degrees(-90)
    case .angle_180:
      return .degrees(-180)
    case .angle_270:
      return .degrees(-270)
    }
  }

  public var transform: CGAffineTransform {
    .init(rotationAngle: angle.radians)
  }

  public func next() -> Self {
    switch self {
    case .angle_0: return .angle_90
    case .angle_90: return .angle_180
    case .angle_180: return .angle_270
    case .angle_270: return .angle_0
    }
  }

  /// Maps from the engine's quarter-turn rotation.
  public init(_ quarterTurn: QuarterTurn) {
    switch quarterTurn {
    case .zero: self = .angle_0
    case .quarterCW: self = .angle_90
    case .half: self = .angle_180
    case .quarterCCW: self = .angle_270
    }
  }

  /// The engine's quarter-turn representation.
  public var quarterTurn: QuarterTurn {
    switch self {
    case .angle_0: return .zero
    case .angle_90: return .quarterCW
    case .angle_180: return .half
    case .angle_270: return .quarterCCW
    }
  }
}
