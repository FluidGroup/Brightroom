//
//  AutoLayout.swift
//  PixelEditor
//
//  Created by Muukii on 2021/02/27.
//  Copyright © 2021 muukii. All rights reserved.
//

import UIKit

enum AutoLayoutTools {
  
  static func setEdge(_ contentView: UIView, _ targetView: UIView) {
    contentView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      contentView.rightAnchor.constraint(equalTo: targetView.rightAnchor),
      contentView.leftAnchor.constraint(equalTo: targetView.leftAnchor),
      contentView.bottomAnchor.constraint(equalTo: targetView.bottomAnchor),
      contentView.topAnchor.constraint(equalTo: targetView.topAnchor),
    ])
  }
}
