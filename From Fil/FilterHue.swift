//
//  FilterHue.swift
//  Fil
//
//  Created by Hiroshi Kimura on 12/15/15.
//  Copyright © 2015 muukii. All rights reserved.
//

import LightRoom

public struct FilterHue: Filtering {

    public static let maximumValue: Double = M_PI
    public static let minimumValue: Double = -M_PI
    public static let neutralValue: Double = 0

    public let value: Double

    public let filterChain: FilterChain

    public init(value: Double) {

        self.value = value
        self.filterChain = {

            let filter = LightRoom.ColorFilter.HueAdjust(angle: value)
            return FilterChain { (image) -> CIImage? in
                image >>> filter
                return filter.outputImage
            }
        }()
    }
}
