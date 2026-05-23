//
// Copyright (c) 2021 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
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

/**
 Apple's Photos app like crop view.
 
 You might use `SwiftUICropView` to create a fully customized user interface.
 */
@available(iOS 14, *)
public struct SwiftUIPhotosCropView: View {

  public struct LocalizedStrings {
    public var button_done_title: String = "Done"
    public var button_cancel_title: String = "Cancel"
    public var button_reset_title: String = "Reset"
    public var button_aspectratio_original: String = "ORIGINAL"
    public var button_aspectratio_freeform: String = "FREEFORM"
    public var button_aspectratio_square: String = "SQUARE"

    public init() {}
  }

  public struct Options: Equatable {

    public enum AspectRatioOptions: Equatable {
      case selectable
      case fixed(PixelAspectRatio?)
    }

    public var aspectRatioOptions: AspectRatioOptions = .selectable

    public init() {

    }
  }

  private let editingStack: EditingStack
  private let options: Options
  private let localizedStrings: LocalizedStrings
  private let onDone: @MainActor () -> Void
  private let onCancel: @MainActor () -> Void

  public init(
    editingStack: EditingStack,
    options: Options = .init(),
    localizedStrings: LocalizedStrings = .init(),
    onDone: @escaping @MainActor () -> Void,
    onCancel: @escaping @MainActor () -> Void
  ) {
    self.editingStack = editingStack
    self.options = options
    self.localizedStrings = localizedStrings
    self.onDone = onDone
    self.onCancel = onCancel
  }

  public var body: some View {
    PhotosCropContentView(
      editingStack: editingStack,
      options: options,
      localizedStrings: localizedStrings,
      onDone: onDone,
      onCancel: onCancel
    )
  }
}

#Preview {
  Text("h")
}
