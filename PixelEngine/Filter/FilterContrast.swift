//
//  FilterContrast.swift
//  Fil
//
//  Created by Muukii on 8/18/15.
//  Copyright © 2015 muukii. All rights reserved.
//

import Foundation

public struct FilterContrast: Filtering, Equatable {

  public static let range: ParameterRange<Double, FilterContrast> = .init(min: -0.18, max: 0.18)
    
    public static let maximumValue: Double = 1.18
    public static let minimumValue: Double = 0.82
    public static let neutralValue: Double = 1
    
  public var value: Double = 0

  public init() {

  }

  public func apply(to image: CIImage) -> CIImage {
    return
      image
        .applyingFilter(
          "CIColorControls",
          parameters: [
            kCIInputContrastKey: 1 + value,
            ]
    )
  }

}
