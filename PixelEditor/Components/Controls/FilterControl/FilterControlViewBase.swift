//
//  FilterControlViewBase.swift
//  PixelEditor
//
//  Created by muukii on 10/17/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

open class FilterControlViewBase : ControlViewBase, ControlChildViewType {

  public override init(context: PixelEditContext) {
    super.init(context: context)
  }

  open override func didMoveToSuperview() {
    super.didMoveToSuperview()

    if superview != nil {
      context.action(.setMode(.filtering))
    } else {
      context.action(.setMode(.preview))
    }

  }
}
