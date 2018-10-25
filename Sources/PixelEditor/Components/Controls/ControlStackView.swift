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

  func push(_ view: UIView & ControlChildViewType, animated: Bool) {
    let controlStackView = find()
    controlStackView.push(view, animated: animated)
  }

  func pop(animated: Bool) {
    find().pop(animated: animated)
  }

  func subscribeChangedEdit(to view: UIView & ControlChildViewType) {
    find().subscribeChangedEdit(to: view)
  }
}


final class ControlStackView : UIView {

  private var subscribers: [UIView & ControlChildViewType] = []

  private var latestNotifiedEdit: EditingStack.Edit?
  
  func push(_ view: UIView & ControlChildViewType, animated: Bool) {
    
    addSubview(view)
    view.frame = bounds
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    
    subscribeChangedEdit(to: view)
    
    if animated {
      view.alpha = 0
      UIView.animate(
        withDuration: 0.2,
        delay: 0,
        options: [.beginFromCurrentState, .curveEaseOut],
        animations: {
          view.alpha = 1
      },
        completion: nil
      )
    }
  }
  
  func pop(animated: Bool) {
    
    guard let target = subviews.last else {
      return
    }
    
    let remove = {
      target.removeFromSuperview()
      self.subscribers.removeAll { $0 == target }
    }
    
    if animated {
      UIView.animate(
        withDuration: 0.2,
        delay: 0,
        options: [.beginFromCurrentState, .curveEaseOut],
        animations: {
          target.alpha = 0
      },
        completion: { _ in
          remove()
      })
    }
    else {
      remove()
    }
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

