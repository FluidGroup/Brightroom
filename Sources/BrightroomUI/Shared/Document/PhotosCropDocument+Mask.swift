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

extension PhotosCropDocument {

  /// Appends a stroke to the blur mask.
  ///
  /// When there is no blur mask yet, one is created with the default blur
  /// (`CropViewMaskingDefaults.blurEffect`, diagonal / 50 of the chain entry)
  /// and a brush-rooted mask tree. An existing blur keeps the content it was
  /// created with.
  ///
  /// - Parameter stroke: A stroke in BrightroomParametric's working space
  ///   (bottom-left origin, y-up) of the oriented, pre-crop source at full
  ///   resolution: x ∈ [0, W], y ∈ [0, H] for (W, H) =
  ///   `EditingStack.Loaded.imageSize`. The brush diameter is in the same
  ///   pixels.
  mutating func appendBlurMaskStroke(_ stroke: BrushMaskStroke) {
    guard blurMask != nil else {
      blurMask = LocalAdjustment(
        maskTree: MaskTree(
          root: .brush(BrushMask(id: MemberID.blurMaskBrush, strokes: [stroke]))
        )
      ) {
        CropViewMaskingDefaults.blurEffect
      }
      return
    }
    blurMask?.maskTree.appendCanvasBrushStroke(stroke)
  }

  /// The blur mask's strokes in working space. Empty when there is no blur
  /// mask or its tree is not rooted at a brush.
  var blurMaskStrokes: [BrushMaskStroke] {
    blurMask?.maskTree.canvasBrushStrokes ?? []
  }
}

// MARK: - Brush-rooted MaskTree access

/// Canvas tooling authors brush-rooted mask trees only. These accessors keep
/// that assumption in one place; composite trees (generated masks, future
/// refinements) pass through untouched and are conservatively treated as
/// selecting something.
extension MaskTree {

  /// The strokes of a brush-rooted tree; empty for composite trees.
  var canvasBrushStrokes: [BrushMaskStroke] {
    guard case let .brush(mask) = root else {
      return []
    }
    return mask.strokes
  }

  /// Appends a stroke to a brush-rooted tree. Composite trees are not
  /// editable by the canvas; appending to one is a programmer error.
  mutating func appendCanvasBrushStroke(_ stroke: BrushMaskStroke) {
    guard case var .brush(mask) = root else {
      assertionFailure("The canvas can only append strokes to a brush-rooted mask tree.")
      return
    }
    mask.strokes.append(stroke)
    root = .brush(mask)
  }
}
