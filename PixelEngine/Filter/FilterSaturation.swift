//
//  Saturation.swift
//  Fil
//
//  Created by Muukii on 8/18/15.
//  Copyright © 2015 muukii. All rights reserved.
//

import Foundation

public struct FilterSaturation: Filtering, Equatable {

  public static let range: ParameterRange<Double, FilterSaturation> = .init(min: -1, max: 1)
    
  public var value: Double = 0

  public init() {

  }

  public func apply(to image: CIImage) -> CIImage {
    return
      image
        .applyingFilter(
          "CIColorControls",
          parameters: [
            kCIInputSaturationKey: 1 + value,
            ]
    )
  }
}
