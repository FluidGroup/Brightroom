//
//  LoadingView.swift
//  PixelEditor
//
//  Created by Antoine Marandon on 08/01/2020.
//  Copyright © 2020 muukii. All rights reserved.
//

import UIKit

class LoadingView: UIView {
  override init(frame: CGRect) {
    super.init(frame: frame)
    let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .light))
    let spinner = UIActivityIndicatorView(style: .whiteLarge)
    self.backgroundColor = .clear
    self.addSubview(blurView)
    self.addSubview(spinner)
    spinner.startAnimating()
    spinner.isHidden = false
    [self, blurView, spinner].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
    NSLayoutConstraint.activate([
      blurView.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      blurView.trailingAnchor.constraint(equalTo: self.trailingAnchor),
      blurView.topAnchor.constraint(equalTo: self.topAnchor),
      blurView.bottomAnchor.constraint(equalTo: self.bottomAnchor),
      spinner.centerYAnchor.constraint(equalTo: self.centerYAnchor),
      spinner.centerXAnchor.constraint(equalTo: self.centerXAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}
