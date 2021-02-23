//
//  LoadingView.swift
//  PixelEditor
//
//  Created by Antoine Marandon on 08/01/2020.
//  Copyright © 2020 muukii. All rights reserved.
//

import UIKit

final class LoadingView: UIView {
  override init(frame: CGRect) {
    
    super.init(frame: frame)
    
    let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .light))
    let spinner = UIActivityIndicatorView(style: .whiteLarge)
    
    self.backgroundColor = .clear
    
    addSubview(blurView)
    addSubview(spinner)
    
    spinner.startAnimating()
    spinner.isHidden = false
    
    [self, blurView, spinner].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
    }
    
    NSLayoutConstraint.activate([
      blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
      blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
      blurView.topAnchor.constraint(equalTo: topAnchor),
      blurView.bottomAnchor.constraint(equalTo: bottomAnchor),
      spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
      spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
    ])
    
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}
