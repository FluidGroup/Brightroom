//
//  BrightnessControlView.swift
//  PixelEditor
//
//  Created by muukii on 10/10/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

import PixelEngine

open class BrightnessControlViewBase : FilterControlViewBase {

  public required init(context: PixelEditContext) {
    super.init(context: context)
  }
}

open class BrightnessControlView : BrightnessControlViewBase {
  
  open override var title: String {
    return L10n.editBrightness
  }

  private let navigationView = NavigationView()

  public let slider = StepSlider(frame: .zero)

  open override func setup() {
    super.setup()

    backgroundColor = Style.default.control.backgroundColor

    TempCode.layout(navigationView: navigationView, slider: slider, in: self)

    slider.addTarget(self, action: #selector(valueChanged), for: .valueChanged)

    navigationView.didTapCancelButton = { [weak self] in
      
      self?.context.action(.revert)
      self?.pop()
    }
    
    navigationView.didTapSaveButton = { [weak self] in
      
      self?.context.action(.commit)
      self?.pop()
    }
  }

  open override func didReceiveCurrentEdit(_ edit: EditingStack.Edit) {

    slider.set(value: edit.filters.brightness?.value ?? 0, in: FilterBrightness.range)

  }

  @objc
  private func valueChanged() {

    let value = slider.transition(in: FilterBrightness.range)
    guard value != 0 else {
      context.action(.setFilter({ $0.brightness = nil }))
      return
    }    
    var f = FilterBrightness()
    f.value = value
    context.action(.setFilter({ $0.brightness = f }))
  }
}
