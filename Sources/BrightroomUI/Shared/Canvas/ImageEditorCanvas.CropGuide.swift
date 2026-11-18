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
    ///
    /// Under `lockedAspectRatio`, a crop the guide recorded or fitted has
    /// exactly that ratio in whole pixels when the ratio's lowest terms are
    /// both at most 32 (1:1, 4:5, 16:9, …): the largest whole multiple of the
    /// terms that fits the guide's whole-pixel size, centered on the guide
    /// within half a pixel. It is smaller than the guide by less than one
    /// term in each dimension (under 16 × 9 pixels for 16:9), and an edge
    /// can lie up to half a pixel outside it. The canvas keeps showing the
    /// guide as the user framed it, and the tool surface and vignette follow
    /// the guide, so until the crop reloads (an undo or redo, or reopening
    /// the document) the framing on screen can be that much larger than the
    /// crop written and exported. Other ratios, and a crop loaded with the
    /// ratio but not recorded since, snap each edge to whole pixels and can
    /// miss the ratio by a pixel.
    public var pendingCrop: CropFeature?

    /// The canvas's bounds, in the canvas's own coordinate space (points,
    /// origin at the top left): the area the image and the guide are laid
    /// out in.
    ///
    /// The canvas reports a new guide when its size changes, on a later
    /// main-actor turn.
    public var canvasBounds: CGRect

    /// Every interaction with the crop in progress; empty when idle. While
    /// the user moves the image and resizes the guide at once it holds both.
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
