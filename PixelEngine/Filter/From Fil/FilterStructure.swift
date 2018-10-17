//
//  FilterStructure.swift
//  Fil
//
//  Created by Muukii on 8/18/15.
//  Copyright © 2015 muukii. All rights reserved.
//

import LightRoom
import LightRoomExtension

public struct FilterStructure: Filtering {
    
    public static let maximumValue: Double = 1
    public static let minimumValue: Double = 0
    public static let neutralValue: Double = 0
    
    public let value: Double
    
    public let filterChain: FilterChain = {
        
        return FilterChain(filterComponent: LightRoom.ExternalFilter.Structure(amount: self.value).filter)
    }
   
    public init(value: Double) {
        
        self.value = value
    }
}
