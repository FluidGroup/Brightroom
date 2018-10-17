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

public final class GaussianBlurControlView : GaussianBlurControlViewBase {

  private let navigationView = NavigationView()

  public let slider = StepSlider(frame: .zero)

  public override func setup() {
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
    }
  }

  @objc
  private func valueChanged() {

    let value = slider.transition(min: range.min, max: range.max)
    var f = FilterGaussianBlur()
    f.value = value
    context.action(.setFilterGaussianBlur(f))
  }

}

