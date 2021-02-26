//
//  Mocks.swift
//  Demo
//
//  Created by Muukii on 2021/02/27.
//  Copyright © 2021 muukii. All rights reserved.
//

import Foundation
import PixelEditor
import PixelEngine

enum Mocks {
  
  static func makeEditingStack() -> EditingStack {
    .init(
      source: .init(image: UIImage(named: "large")!),
      previewSize: CGSize(width: 600, height: 600)
    )
  }
}
