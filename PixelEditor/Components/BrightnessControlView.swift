//
//  BrightnessControlView.swift
//  PixelEditor
//
//  Created by muukii on 10/10/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

import struct PixelEngine.ParameterRange

open class BrightnessControlViewBase : ControlViewBase {

  public final let range: ParameterRange<Double>

  init(range: ParameterRange<Double>, context: PixelEditContext) {
    self.range = range
    super.init(context: context)
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
