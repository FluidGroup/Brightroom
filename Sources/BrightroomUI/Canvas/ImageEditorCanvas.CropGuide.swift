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

import BrightroomParametric
import CoreGraphics

extension ImageEditorCanvas {

  /// The state of the canvas's crop guide, reported by
  /// `onCropGuideChange(_:)`.
  public struct CropGuide: Equatable, Sendable {

    /// The crop the guide shows, which applying the pending crop writes to
    /// the document; nil until the canvas has loaded the document.
    ///
    /// It is pixel-aligned, and like `ImageEditorFeature.crop` it is in y-up
    /// coordinates of the oriented, pre-crop source image, with `rect` the
    /// selection before the quarter turn. The output size is
    /// `pendingCrop.outputGeometry(in: .zero).outputBounds.size`.
    public var pendingCrop: CropFeature?

    /// The canvas's bounds, in the canvas's own coordinate space (points,
    /// origin at the top left): the area the image and the guide are laid
    /// out in.
    ///
    /// A change of size alone is not reported; the value is the one current
    /// when another member changed.
    public var canvasBounds: CGRect

    /// What the user is doing to the crop; empty when idle.
    public var interaction: CropInteraction

    /// The locked aspect ratio in the output orientation, or nil when the
    /// guide is free.
    public var lockedAspectRatio: AspectRatio?

    public init(
      pendingCrop: CropFeature?,
      canvasBounds: CGRect,
      interaction: CropInteraction,
      lockedAspectRatio: AspectRatio?
    ) {
      self.pendingCrop = pendingCrop
      self.canvasBounds = canvasBounds
      self.interaction = interaction
      self.lockedAspectRatio = lockedAspectRatio
    }
  }
}
