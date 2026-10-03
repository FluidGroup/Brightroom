//
// Copyright (c) 2026 Muukii <muukii.app@gmail.com>
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


/// What the user is doing to the crop in `ImageEditorCanvas`: every
/// interaction in progress. The empty set means idle.
///
/// Interactions can overlap, such as moving the image with one finger while
/// resizing the guide with another; the set then holds both, and it becomes
/// empty only when the last one ends. `ImageEditorCanvas.CropGuide.interaction`
/// and the crop overlay builders receive the same value.
public struct CropInteraction: OptionSet, Equatable, Sendable {

  public let rawValue: Int

  public init(rawValue: Int) {
    self.rawValue = rawValue
  }

  /// Panning or zooming the image under the crop guide, including the
  /// image's deceleration after a flick.
  public static let movingImage = CropInteraction(rawValue: 1 << 0)

  /// Dragging the crop guide's edges or corners.
  public static let resizingGuide = CropInteraction(rawValue: 1 << 1)
}
