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

  public final let range = FilterBrightness.range

  public override init(context: PixelEditContext) {
    super.init(context: context)
  }

}

open class BrightnessControlView : BrightnessControlViewBase {

  private let navigationView = NavigationView()

  public let slider = StepSlider(frame: .zero)

  open override func setup() {
    super.setup()

    backgroundColor = Style.default.control.backgroundColor

    addSubview(slider)
    addSubview(navigationView)

    slider.translatesAutoresizingMaskIntoConstraints = false

    navigationView.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([

      slider.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
      slider.rightAnchor.constraint(equalTo: rightAnchor, constant: -44),
      slider.leftAnchor.constraint(equalTo: leftAnchor, constant: 44),
      slider.centerYAnchor.constraint(equalTo: centerYAnchor),

      navigationView.topAnchor.constraint(greaterThanOrEqualTo: slider.bottomAnchor),
      navigationView.rightAnchor.constraint(equalTo: navigationView.superview!.rightAnchor),
      navigationView.leftAnchor.constraint(equalTo: navigationView.superview!.leftAnchor),
      navigationView.bottomAnchor.constraint(equalTo: navigationView.superview!.bottomAnchor),
      ])

    slider.addTarget(self, action: #selector(valueChanged), for: .valueChanged)

    navigationView.didTapCancelButton = { [weak self] in

      self?.pop()
      self?.context.action(.revert)
    }

    navigationView.didTapSaveButton = { [weak self] in

      self?.pop()
      self?.context.action(.commit)
    }
  }

  open override func didReceiveCurrentEdit(_ edit: EditingStack.Edit) {

    slider.set(value: edit.filters.brightness?.value ?? 0, in: range)

  }

  @objc
  private func valueChanged() {

    let value = slider.transition(in: range)
    var f = FilterBrightness()
    f.value = value
    context.action(.setFilterBrightness(f))
  }
}
