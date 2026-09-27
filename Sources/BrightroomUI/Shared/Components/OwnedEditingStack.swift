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

/// Prepares an image for the lifetime of this view's identity.
///
/// Give it an identity per image (`.id(image)`): the stack is created once
/// per identity and released with it, so the GPU-resident editing source
/// lives only while an editor shows the image.
struct OwnedEditingStack<Content: View>: View {

  // `State(initialValue:)` is evaluated on every init but kept only for a
  // new identity. A stack costs nothing until `start()`, so the discarded
  // ones are cheap.
  @State private var stack: EditingStack

  private let content: (EditingStack) -> Content

  init(image: SourceImage, @ViewBuilder content: @escaping (EditingStack) -> Content) {
    self._stack = State(initialValue: EditingStack(image: image))
    self.content = content
  }

  var body: some View {
    content(stack)
  }
}
