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


import CoreGraphics

import BrightroomParametric

extension ImageEditorFeature {

  /// The blur a new local blur starts with. Its radius resolves against the
  /// render pass's chain-entry extent, so the apparent strength is comparable
  /// across image sizes and render resolutions.
  ///
  /// `GaussianBlurFeature(radius: .proportional(40))` resolves to diagonal/20 × 40/100 =
  /// diagonal/50 — the strength the legacy crop-frozen seed produced. Because
  /// the value form is scale-invariant, the default does not depend on the
  /// current crop and can be a constant.
  static let defaultLocalBlurContent = GaussianBlurFeature(radius: .proportional(40))

  /// Appends a stroke to the local blur's mask.
  ///
  /// When there is no local blur yet, one is created with the default blur
  /// (`defaultLocalBlurContent`, diagonal / 50 of the chain entry)
  /// and a brush mask. An existing blur keeps the content it was
  /// created with.
  ///
  /// - Parameter stroke: A stroke in BrightroomParametric's working space
  ///   (bottom-left origin, y-up) of the oriented, pre-crop source at full
  ///   resolution: x ∈ [0, W], y ∈ [0, H] for (W, H) =
  ///   `EditingStack.Loaded.imageSize`. The brush diameter is in the same
  ///   pixels.
  mutating func appendLocalBlurStroke(_ stroke: BrushMask.Stroke) {
    guard localBlur != nil else {
      localBlur = LocalAdjustmentFeature(
        mask: .brush(BrushMask(strokes: [stroke]))
      ) {
        Self.defaultLocalBlurContent
      }
      return
    }
    localBlur?.mask.appendCanvasBrushStroke(stroke)
  }

  /// The local blur's strokes in working space. Empty when there is no local
  /// blur or its mask is not a brush mask.
  var localBlurStrokes: [BrushMask.Stroke] {
    localBlur?.mask.canvasBrushStrokes ?? []
  }
}

// MARK: - Brush-rooted Mask access

/// Canvas tooling authors brush masks only. These accessors keep that
/// assumption in one place. Composite masks (generated masks, future
/// refinements) pass through untouched: they render at export, but the canvas
/// has no strokes to preview for them.
extension Mask {

  /// The strokes of a brush mask; empty for composite masks.
  var canvasBrushStrokes: [BrushMask.Stroke] {
    guard case let .brush(mask) = self else {
      return []
    }
    return mask.strokes
  }

  /// Appends a stroke to a brush mask. Composite masks are not editable by
  /// the canvas; appending to one is a programmer error.
  mutating func appendCanvasBrushStroke(_ stroke: BrushMask.Stroke) {
    guard case var .brush(mask) = self else {
      assertionFailure("The canvas can only append strokes to a brush mask.")
      return
    }
    mask.strokes.append(stroke)
    self = .brush(mask)
  }
}
