//
//  FilterGrain.swift
//  Fil
//
//  Created by Hiroshi Kimura on 12/20/15.
//  Copyright © 2015 muukii. All rights reserved.
//

import LightRoom
import LightRoomExtension

public struct FilterGrain: Filtering {

    public static let maximumValue: Double = 0.7
    public static let minimumValue: Double = 0
    public static let neutralValue: Double = 0

    public let value: Double

    public let filterChain: FilterChain

    public init(value: Double) {

        self.value = value
        self.filterChain = {

            return LightRoom.ExternalFilter.Grain(intencity: value)
        }()
    }
}
