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

#if !COCOAPODS
import BrightroomEngine
#endif

/**
 Apple's Photos app like crop view controller.
 
 You might use `CropView` to create a fully customized user interface.
 */
@available(iOS 13, *)
public struct SwiftUIPhotosCropView: UIViewControllerRepresentable {
  public typealias UIViewControllerType = PhotosCropViewController
  
  private let editingStack: EditingStack
  private let onCompleted: () -> Void
  
  public init(editingStack: EditingStack, onCompleted: @escaping () -> Void) {
    self.editingStack = editingStack
    self.onCompleted = onCompleted
    editingStack.start()
  }
  
  public func makeUIViewController(context: Context) -> PhotosCropViewController {
    let cropViewController = PhotosCropViewController(editingStack: editingStack)
    cropViewController.handlers.didFinish = { _ in
      onCompleted()
    }
    cropViewController.handlers.didCancel = { _ in
      onCompleted()
    }
    return cropViewController
  }
  
  public func updateUIViewController(_ uiViewController: PhotosCropViewController, context: Context) {}
}
