//
//  BrightnessControlView.swift
//  PixelEditor
//
//  Created by muukii on 10/10/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

import struct PixelEngine.ParameterRange

open class BrightnessControlViewBase : UIView {

  public final var range: ParameterRange<Double> {
    fatalError()
  }

  init(range: ParameterRange<Double>) {
    super.init(frame: .zero)
    setup()
  }

  @available(*, unavailable)
  public required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  open func setup() {

  }

  open func set(brightness: Double) {

  }

  open func didChange(brightness: Double) {

  }
}

public final class BrightnessControlView : BrightnessControlViewBase {

  public override func setup() {
    super.setup()

    backgroundColor = .white
  }
}
