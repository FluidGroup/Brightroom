//
//  TempCode.swift
//  PixelEditor
//
//  Created by Hiroshi Kimura on 2018/10/19.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

enum TempCode {
  
  static func layout(navigationView: NavigationView, slider: StepSlider, in view: UIView) {
    
    view.addSubview(slider)
    view.addSubview(navigationView)
    
    slider.translatesAutoresizingMaskIntoConstraints = false
    
    navigationView.translatesAutoresizingMaskIntoConstraints = false
    
    NSLayoutConstraint.activate([
      
      slider.topAnchor.constraint(greaterThanOrEqualTo: slider.superview!.topAnchor),
      slider.rightAnchor.constraint(equalTo: slider.superview!.rightAnchor, constant: -44),
      slider.leftAnchor.constraint(equalTo: slider.superview!.leftAnchor, constant: 44),
      slider.centerYAnchor.constraint(equalTo: slider.superview!.centerYAnchor),
      
      navigationView.topAnchor.constraint(greaterThanOrEqualTo: slider.bottomAnchor),
      navigationView.rightAnchor.constraint(equalTo: navigationView.superview!.rightAnchor),
      navigationView.leftAnchor.constraint(equalTo: navigationView.superview!.leftAnchor),
      navigationView.bottomAnchor.constraint(equalTo: navigationView.superview!.bottomAnchor),
      ])

  }
}
