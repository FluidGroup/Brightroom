//
//  ControlStackView.swift
//  PixelEditor
//
//  Created by muukii on 10/10/18.
//  Copyright © 2018 muukii. All rights reserved.
//

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

