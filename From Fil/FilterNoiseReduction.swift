//
//  FilterNoiseReduction.swift
//  Fil
//
//  Created by Muukii on 11/15/15.
//  Copyright © 2015 muukii. All rights reserved.
//

import LightRoom

public struct FilterNoiseReduction: Filtering {

    public static let maximumValue: Double = 0.08
    public static let minimumValue: Double = 0
    public static let neutralValue: Double = 0

    public let value: Double

    public let filterChain: FilterChain

    public init(value: Double) {

        self.value = value
        self.filterChain = {

            let filter = LightRoom.Blur.NoiseReduction(noiseLevel: value, sharpness: 0.2)

            return FilterChain { (image) -> CIImage? in
                image >>> filter
                return filter.outputImage
            }
        }()
    }
}
