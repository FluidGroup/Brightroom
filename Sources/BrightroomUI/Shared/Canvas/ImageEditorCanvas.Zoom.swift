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
import Foundation

extension ImageEditorCanvas {

  /// A canvas's zoom, reported on macOS: canvas points per full-resolution
  /// pixel of the crop output it shows, and its limits.
  struct Zoom: Equatable, Sendable {

    var scale: CGFloat
    var fitScale: CGFloat
    var maximumScale: CGFloat
    /// The display scale of the canvas's window.
    var backingScaleFactor: CGFloat

    /// Where the zoom is from the fit (0) to the maximum (1), along its
    /// logarithm, so equal steps zoom by equal factors; 0 for a degenerate
    /// range.
    var fraction: Double {
      guard fitScale > 0, maximumScale > fitScale else { return 0 }
      let fraction = Double(log(scale / fitScale) / log(maximumScale / fitScale))
      return min(max(fraction, 0), 1)
    }

    /// Whether the zoom is the fit, within a millionth of it.
    var isFitted: Bool {
      Self.isClose(scale, to: fitScale)
    }

    /// Whether the zoom is the maximum, within a millionth of it.
    var isAtMaximum: Bool {
      Self.isClose(scale, to: maximumScale)
    }

    /// Device pixels per output pixel, in percent, rounded: 100 shows each
    /// pixel of the output on one pixel of the display. A zoom beyond any
    /// `Int`, which a degenerate crop can fit at, is `Int.max`.
    var percent: Int {
      let percent = (scale * backingScaleFactor * 100).rounded()
      return Int(exactly: percent) ?? (percent > 0 ? .max : 0)
    }

    /// The zoom at `fraction` (clamped to 0...1) of the way from the fit to
    /// the maximum, the inverse of `fraction`; the fit for a degenerate
    /// range.
    static func scale(
      atFraction fraction: Double,
      fitScale: CGFloat,
      maximumScale: CGFloat
    ) -> CGFloat {
      guard fitScale > 0, maximumScale > fitScale else { return fitScale }
      return fitScale * pow(maximumScale / fitScale, CGFloat(min(max(fraction, 0), 1)))
    }

    private static func isClose(_ scale: CGFloat, to limit: CGFloat) -> Bool {
      abs(scale - limit) <= 1e-6 * max(limit, .leastNonzeroMagnitude)
    }
  }
}
