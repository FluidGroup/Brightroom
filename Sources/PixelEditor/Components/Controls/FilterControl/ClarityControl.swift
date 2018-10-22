//
//  UnsharpMaskControl.swift
//  PixelEditor
//
//  Created by Hiroshi Kimura on 2018/10/22.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

import PixelEngine

open class ClarityControlViewBase : FilterControlViewBase {
  
  public required init(context: PixelEditContext) {
    super.init(context: context)
  }
}

open class ClarityControlView : ClarityControlViewBase {
  
  open override var title: String {
    return L10n.editClarity
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
    
    slider.set(value: edit.filters.unsharpMask?.intensity ?? 0, in: FilterUnsharpMask.Params.intensity)
    
  }
  
  @objc
  private func valueChanged() {
    
    let value = slider.transition(in: FilterUnsharpMask.Params.intensity)
    
    guard value != 0 else {
      context.action(.setFilter({ $0.unsharpMask = nil }))
      return
    }
    
    var f = FilterUnsharpMask()
    f.intensity = value
    f.radius = 0.12
    context.action(.setFilter({ $0.unsharpMask = f }))
  }
  
}
