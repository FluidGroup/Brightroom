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


import SwiftUI

import BrightroomEngine

/// Gives its content one `PreviewSourceLoader` for a source image, kept for
/// the lifetime of this view's identity.
///
/// Wrap the views of one open image in a reader, and give the reader an
/// identity per source image with `.id(source)`: the loader is created once
/// per identity and released with it, so the image is decoded once while it
/// is open, and its GPU-resident editing copy lives only that long. A reader
/// without that identity keeps the loader of the first source it was given.
///
/// The content shares the loader: pass it to
/// `ImageEditorCanvas(document:previewSourceLoader:)`, and pass its
/// `previewSource`, once loaded, to the views that read the canvas's pixels.
/// The canvas starts loading when it appears; a view that needs the pixels
/// without a canvas starts it with `.task { await loader.load() }`.
///
/// ```swift
/// PreviewSourceReader(source: document.source) { loader in
///   // One loader per image: the canvas and the other views share its decode.
///   ImageEditorCanvas(document: $document, previewSourceLoader: loader)
///   if let previewSource = loader.previewSource {
///     // A histogram, filter swatches or a gray point: pass previewSource.
///   }
/// }
/// .id(document.source)
/// ```
public struct PreviewSourceReader<Content: View>: View {

  // `State(initialValue:)` is evaluated on every init but kept only for a
  // new identity. A loader costs nothing until `load()`, so the discarded
  // ones are cheap.
  @State private var loader: PreviewSourceLoader

  private let content: (PreviewSourceLoader) -> Content

  /// Creates a reader whose content receives the loader of `source`.
  public init(
    source: SourceImage,
    @ViewBuilder content: @escaping (PreviewSourceLoader) -> Content
  ) {
    self._loader = State(initialValue: PreviewSourceLoader(source: source))
    self.content = content
  }

  public var body: some View {
    content(loader)
  }
}
