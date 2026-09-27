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

/// The one crossing between the canvas and the document for mask strokes.
///
/// The canvas authors strokes in the canvas source space: the oriented,
/// pre-crop, full-resolution pixel grid with a top-left origin, y-down. The
/// document stores them in BrightroomParametric's working space: the same grid
/// with a bottom-left origin, y-up. The conversion (x, y) ↦ (x, H − y) is its
/// own inverse. Diameter, hardness, and opacity carry over unchanged because
/// both spaces use the same pixels.
extension EditingCanvasStrokeRecord {

  /// Converts a canvas-source record (y-down) into a mask stroke in the
  /// working space (y-up) of the same domain.
  ///
  /// - Parameter domainHeight: The height of the domain, the oriented source
  ///   height `EditingStack.Loaded.imageSize.height`.
  func workingSpaceStroke(domainHeight: CGFloat) -> BrushMaskStroke {
    BrushMaskStroke(
      stamps: stamps.map { CGPoint(x: $0.x, y: domainHeight - $0.y) },
      brush: .init(
        diameter: brush.size,
        hardness: brush.hardness,
        opacity: brush.opacity
      )
    )
  }

  /// Converts a working-space mask stroke (y-up) back into a canvas-source
  /// record (y-down). Used only to display committed strokes on the canvas.
  ///
  /// - Parameter domainHeight: The height of the domain, the oriented source
  ///   height `EditingStack.Loaded.imageSize.height`.
  init(workingSpaceStroke stroke: BrushMaskStroke, domainHeight: CGFloat) {
    self.init(
      stamps: stroke.stamps.map { CGPoint(x: $0.x, y: domainHeight - $0.y) },
      brush: .init(
        size: stroke.brush.diameter,
        hardness: stroke.brush.hardness,
        opacity: stroke.brush.opacity,
        // `BrushMaskStroke` does not store spacing; committed strokes render
        // from their stored stamps, so this is a placeholder kept in sync with
        // the authoring default (ImageEditorCanvas.Brush / EditingCanvasBrush).
        spacing: 0.05
      )
    )
  }
}
