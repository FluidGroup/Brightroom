//
//  SliderViewController.swift
//  Demo
//
//  Created by muukii on 10/16/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

import PixelEditor

final class SliderViewController : UIViewController {

  public let slider = StepSlider(frame: .zero)

  override func viewDidLoad() {
    super.viewDidLoad()

    view.addSubview(slider)

    slider.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      slider.topAnchor.constraint(greaterThanOrEqualTo: view.topAnchor),
      slider.rightAnchor.constraint(equalTo: view.rightAnchor, constant: -44),
      slider.leftAnchor.constraint(equalTo: view.leftAnchor, constant: 44),
      slider.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),
      slider.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      ])
  }
}
