//
// Copyright (c) 2018 Muukii <muukii.app@gmail.com>
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

import UIKit

import PixelEngine


protocol ControlChildViewType {

  func didReceiveCurrentEdit(_ edit: EditingStack.Edit)
}

extension ControlChildViewType where Self : UIView {

  private func find() -> ControlStackView {

    var _super: UIView?
    _super = superview
    while _super != nil {
      if let target = _super as? ControlStackView {
        return target
      }
      _super = _super?.superview
    }

    fatalError()

  }

  func push(_ view: UIView & ControlChildViewType) {
    let controlStackView = find()
    controlStackView.push(view)
  }

  func pop() {
    find().pop()
  }

  func subscribeChangedEdit(to view: UIView & ControlChildViewType) {
    find().subscribeChangedEdit(to: view)
  }
}


final class ControlStackView : UIView {

  private var subscribers: [UIView & ControlChildViewType] = []

  private var latestNotifiedEdit: EditingStack.Edit?

  func push(_ view: UIView & ControlChildViewType) {

    addSubview(view)
    view.frame = bounds
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]

    subscribeChangedEdit(to: view)
  }

  func pop() {

    guard let target = subviews.last else {
      return
    }
    target.removeFromSuperview()

    subscribers.removeAll { $0 == target }
  }

  func subscribeChangedEdit(to view: UIView & ControlChildViewType) {
    guard !subscribers.contains(where: { $0 == view }) else { return }
    subscribers.append(view)
    if let edit = latestNotifiedEdit {
      view.didReceiveCurrentEdit(edit)
    }
  }

  func notify(changedEdit: EditingStack.Edit) {

    latestNotifiedEdit = changedEdit

    subscribers
      .forEach {
        $0.didReceiveCurrentEdit(changedEdit)
    }
  }
}

