//
//  GaussianBlurControlView.swift
//  PixelEditor
//
//  Created by muukii on 10/17/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

import PixelEngine


open class GaussianBlurControlViewBase : FilterControlViewBase {

  public final let range = FilterGaussianBlur.range

  public override init(context: PixelEditContext) {
    super.init(context: context)
  }

}

open class GaussianBlurControlView : GaussianBlurControlViewBase {
  
  open override var title: String {
    return TODOL10n("Blur")
  }

  private let navigationView = NavigationView()

  public let slider = StepSlider(frame: .zero)

  open override func setup() {
    super.setup()

    backgroundColor = Style.default.control.backgroundColor

    TempCode.layout(navigationView: navigationView, slider: slider, in: self)

    slider.mode = .plus
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

    slider.set(value: edit.filters.gaussianBlur?.value ?? 0, in: range)

  }

  @objc
  private func valueChanged() {

    let value = slider.transition(min: range.min, max: range.max)
    
    guard value != 0 else {
      context.action(.setFilter({ $0.gaussianBlur = nil }))
      return
    }
    
    var f = FilterGaussianBlur()
    f.value = value
    context.action(.setFilter({ $0.gaussianBlur = f }))
  }

}

