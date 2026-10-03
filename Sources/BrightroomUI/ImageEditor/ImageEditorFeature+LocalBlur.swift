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

  /// Whether the editor can paint `localBlur`: true when there is no local
  /// blur yet or its mask is a plain `.brush`.
  ///
  /// The editing canvas rasterizes brush strokes only, so it cannot show any
  /// other mask (for example `.inverted`, `.feathered`, `.union`,
  /// `.intersection`, or `.subtraction`, as a host may restore). While this is
  /// false, `ImageEditorCanvas` paints nothing for the `.localBlur` target,
  /// and `ImageEditor`'s Blur mode disables the brush but keeps Clear. The
  /// mask still renders at export. Removing the local blur (`localBlur =
  /// nil`, or Clear in `ImageEditor`'s Blur mode) makes it paintable again.
  public var isLocalBlurPaintable: Bool {
    guard let localBlur else {
      return true
    }
    guard case .brush = localBlur.mask else {
      return false
    }
    return true
  }

  /// Appends a stroke to the local blur's brush mask.
  ///
  /// When there is no local blur yet, one is created with the default blur
  /// (`defaultLocalBlurContent`, diagonal / 50 of the chain entry)
  /// and a brush mask. An existing blur keeps the content it was
  /// created with.
  ///
  /// When the local blur is not paintable (`isLocalBlurPaintable`), the
  /// feature is left unchanged. The canvas does not paint such a blur; this
  /// covers a stroke that reaches a document whose mask the host replaced
  /// while the stroke was drawn.
  ///
  /// - Parameter stroke: A stroke in BrightroomParametric's working space
  ///   (bottom-left origin, y-up) of the oriented, pre-crop source at full
  ///   resolution: x ∈ [0, W], y ∈ [0, H] for (W, H) =
  ///   `SourceImage.pixelSize`. The brush diameter is in the same
  ///   pixels.
  mutating func appendLocalBlurStroke(_ stroke: BrushMask.Stroke) {
    guard var localBlur else {
      self.localBlur = LocalAdjustmentFeature(
        mask: .brush(BrushMask(strokes: [stroke]))
      ) {
        Self.defaultLocalBlurContent
      }
      return
    }
    guard case var .brush(brush) = localBlur.mask else {
      return
    }
    brush.strokes.append(stroke)
    localBlur.mask = .brush(brush)
    self.localBlur = localBlur
  }

  /// The local blur's strokes in working space. Empty when there is no local
  /// blur or its mask is not a brush mask.
  var localBlurStrokes: [BrushMask.Stroke] {
    localBlur?.mask.brushStrokes ?? []
  }
}

// MARK: - Brush-rooted Mask access

/// Canvas tooling authors and previews brush masks only
/// (`ImageEditorFeature.isLocalBlurPaintable`). Other masks pass through
/// untouched: they render at export, but the canvas has no strokes to preview
/// for them.
extension Mask {

  /// The strokes of a brush mask; empty for any other mask.
  var brushStrokes: [BrushMask.Stroke] {
    guard case let .brush(mask) = self else {
      return []
    }
    return mask.strokes
  }
}
