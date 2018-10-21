//
//  File.swift
//  Fil
//
//  Created by Muukii on 8/18/15.
//  Copyright © 2015 muukii. All rights reserved.
//

import Foundation
import CoreImage

public struct FilterHighlights: Filtering, Equatable, Codable {

  public static let range: ParameterRange<Double, FilterHighlights> = .init(min: 0, max: 1)

  public var value: Double = 0

  public init() {

  }

  public func apply(to image: CIImage, sourceImage: CIImage) -> CIImage {

    return
      image
        .applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": 1 - value])
  }
}
