//
//  File.swift
//  Fil
//
//  Created by Muukii on 8/18/15.
//  Copyright © 2015 muukii. All rights reserved.
//

import Foundation
import CoreImage

public struct FilterHighlights: Filtering, Equatable {

  public static let range: ParameterRange<Double, FilterHighlights> = .init(min: 0, max: 0.8)

  public var value: Double

  public init(value: Double) {

    self.value = value
  }

  public func apply(to image: CIImage) -> CIImage {

    return
      image
        .applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": 1 - value])
  }
}
