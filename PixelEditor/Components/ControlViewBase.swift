//
//  ControlViewBase.swift
//  PixelEditor
//
//  Created by muukii on 10/11/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

open class ControlViewBase : UIView {

  public let context: PixelEditContext

  public init(context: PixelEditContext) {
    self.context = context
    super.init(frame: .zero)
    setup()
  }

  @available(*, unavailable)
  public required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  open func setup() {

  }
}
