//
//  ParameterRange.swift
//  PixelEngine
//
//  Created by muukii on 10/10/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

public struct ParameterRange<T : Comparable, Target> {

  public let min: T
  public let max: T

  public init(min: T, max: T) {
    self.min = min
    self.max = max
  }

}
