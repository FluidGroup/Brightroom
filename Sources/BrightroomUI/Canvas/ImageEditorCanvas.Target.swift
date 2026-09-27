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


extension ImageEditorCanvas {

  /// The part of an `ImageEditorFeature` that the canvas's gestures edit:
  /// the adjustment point in `docs/vision-of-editing.md`.
  ///
  /// The canvas always shows the feature's output (the viewing point); the
  /// target only picks what gestures change. `nil` shows the output without
  /// editing anything.
  public enum Target: Equatable, Sendable {

    /// Edit `crop` with the guide and the scroll surface. The canvas shows the
    /// feature with the crop neutralized.
    case crop

    /// Paint `localBlur`. The canvas shows the whole feature through the crop.
    case localBlur
  }
}
