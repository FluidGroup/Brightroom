//
//  Sharpen.swift
//  Fil
//
//  Created by Muukii on 8/18/15.
//  Copyright © 2015 muukii. All rights reserved.
//

import Foundation
import CoreImage

public struct FilterSharpen: Filtering, Equatable, Codable {

  public static let range: ParameterRange<Double, FilterSharpen> = .init(min: 0, max: 1.2)

  public var value: Double = 0

  public init() {

  }

  public func apply(to image: CIImage, sourceImage: CIImage) -> CIImage {

    let radius = RadiusCalculator.radius(value: value, max: FilterGaussianBlur.range.max, imageExtent: image.extent)

    return
      image
        .applyingFilter(
          "CISharpenLuminance", parameters: [
            kCIInputSharpnessKey: radius,
            ])
  }
}
