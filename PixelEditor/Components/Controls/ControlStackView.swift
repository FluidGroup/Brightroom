//
//  ControlStackView.swift
//  PixelEditor
//
//  Created by muukii on 10/10/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import UIKit

protocol ControlChildViewType {

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
    let controlStackView = find()
    controlStackView.pop()
  }
}


final class ControlStackView : UIView {

  func push(_ view: UIView & ControlChildViewType) {

    addSubview(view)
    view.frame = bounds
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
  }

  func pop() {

    subviews.last?.removeFromSuperview()
  }
}

