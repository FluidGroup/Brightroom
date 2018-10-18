//
//  Warmth.swift
//  Fil
//
//  Created by Muukii on 8/18/15.
//  Copyright © 2015 muukii. All rights reserved.
//

import Foundation
import CoreImage

public struct FilterTemperature: Filtering, Equatable {

  public static let range: ParameterRange<Double, FilterTemperature> = .init(min: -3000, max: 3000)

  public var value: Double = 0

  public init() {

  }

  public func apply(to image: CIImage) -> CIImage {
    return
      image
        .applyingFilter(
          "CITemperatureAndTint",
          parameters: [
            "inputNeutral": CIVector.init(x: CGFloat(value) + 6500, y: 0),
            "inputTargetNeutral": CIVector.init(x: 6500, y: 0),
          ]
    )
  }


}
