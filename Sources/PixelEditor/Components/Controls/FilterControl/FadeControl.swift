//
//  FadeControl.swift
//  PixelEditor
//
//  Created by Hiroshi Kimura on 2018/10/22.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

import PixelEngine

open class FadeControlViewBase : FilterControlViewBase {
  
  public required init(context: PixelEditContext) {
    super.init(context: context)
  }
}

open class FadeControlView : FadeControlViewBase {
  
  open override var title: String {
    return L10n.editFade
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
    
    slider.set(value: edit.filters.fade?.intensity ?? 0, in: FilterFade.Params.intensity)
    
  }
  
  @objc
  private func valueChanged() {
    
    let value = slider.transition(in: FilterFade.Params.intensity)
    
    guard value != 0 else {
      context.action(.setFilter({ $0.fade = nil }))
      return
    }
    
    var f = FilterFade()
    f.intensity = value
    context.action(.setFilter({ $0.fade = f }))
  }
  
}
