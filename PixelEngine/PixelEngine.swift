//
//  PixelEngine.swift
//  PixelEngine
//
//  Created by muukii on 10/13/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

extension CGFloat {

  mutating func ceil() {
    self = Darwin.ceil(self)
  }
}

extension CGRect {

  /// Round x, y, width, height
  func ceiled() -> CGRect {

    var _rect = self

    _rect.origin.x.ceil()
    _rect.origin.y.ceil()
    _rect.size.width.ceil()
    _rect.size.height.ceil()

    return _rect

  }

  /// Round x, y, width, height
  func rounded() -> CGRect {

    var _rect = self

    _rect.origin.x.round()
    _rect.origin.y.round()
    _rect.size.width.round()
    _rect.size.height.round()

    return _rect

  }
}
