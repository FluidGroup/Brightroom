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

/// Gives its content one `PreviewSourceLoader` for the lifetime of this view's
/// identity.
///
/// Give it an identity per source image (`.id(source)`): the loader is created
/// once per identity and released with it, so the GPU-resident editing source
/// lives only while an editor shows the image. The content starts loading
/// (`await loader.load()` in a `.task`); every view of one identity shares the
/// loader, so the image is decoded once.
struct PreviewSourceReader<Content: View>: View {

  // `State(initialValue:)` is evaluated on every init but kept only for a
  // new identity. A loader costs nothing until `load()`, so the discarded
  // ones are cheap.
  @State private var loader: PreviewSourceLoader

  private let content: (PreviewSourceLoader) -> Content

  init(source: SourceImage, @ViewBuilder content: @escaping (PreviewSourceLoader) -> Content) {
    self._loader = State(initialValue: PreviewSourceLoader(source: source))
    self.content = content
  }

  var body: some View {
    content(loader)
  }
}
