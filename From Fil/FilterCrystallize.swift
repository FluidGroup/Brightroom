//
//  FilterCrystalize.swift
//  Fil
//
//  Created by muukii on 4/16/16.
//  Copyright © 2016 muukii. All rights reserved.
//

import LightRoom

public struct FilterCrystallize: Filtering {

    public static let maximumValue: Double = 60
    public static let minimumValue: Double = 10
    public static let neutralValue: Double = 10

    public let value: Double

    public let filterChain: FilterChain

    public init(value: Double) {

        self.value = value
        self.filterChain = {

            let clamp = LightRoom.TileEffect.AffineClamp(transform: CGAffineTransform(scaleX: 1,y: 1))

            return FilterChain { (image) -> CIImage? in

                guard let image = image else {
                    return nil
                }
                let radius = RadiusCalculator.radius(image.extent) * value / FilterCrystallize.maximumValue
                let filter = LightRoom.Stylize.Crystallize(radius: radius)

                image >>> clamp >>> filter
                return filter.outputImage?.cropping(to: image.extent)
            }
        }()
    }
}
