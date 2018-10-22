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

public struct OvalBrush : Equatable {

  public static func == (lhs: OvalBrush, rhs: OvalBrush) -> Bool {
    guard lhs.color == rhs.color else { return false }
    guard lhs.width == rhs.width else { return false }
    guard lhs.alpha == rhs.alpha else { return false }
    guard lhs.blendMode == rhs.blendMode else { return false }
    return true
  }

  // MARK: - Properties

  public let color: UIColor
  public let width: CGFloat
  public let alpha: CGFloat
  public let blendMode: CGBlendMode

  // MARK: - Initializers

  public init(
    color: UIColor,
    width: CGFloat,
    alpha: CGFloat = 1,
    blendMode: CGBlendMode = .normal
    ) {

    self.color = color
    self.width = width
    self.alpha = alpha
    self.blendMode = blendMode
  }
}
