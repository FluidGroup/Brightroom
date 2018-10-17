//
//  PresetAmount.swift
//  Fil
//
//  Created by Muukii on 10/13/15.
//  Copyright © 2015 muukii. All rights reserved.
//

import LightRoom
import JAYSON
import FilModel
import RealmSwift

public struct FilterPresetAmount: Filtering {
    
    public static let maximumValue: Double = 1
    public static let minimumValue: Double = 0
    public static let neutralValue: Double = 1
    
    public let value: Double
    
    public var preset: CubeFilter! {
        return try! RealmStack.Data.detach().object(ofType: CubeFilter.self, forPrimaryKey: presetName)
    }
    
    public let presetName: String
    
    public init(value: Double) {
        
        fatalError("Don't use.")
    }
    
    public init(value: Double = FilterPresetAmount.neutralValue, preset: CubeFilter) {
        
        self.value = value
        self.presetName = preset.name
        
        self.filterChain = {
            
            let presetFilter = preset.filter(value)
            
            return presetFilter
        }()
    }
    
    public init?(jayson: JAYSON) {
        
        guard let value = jayson[Keys.Value].double,
            let presetName = jayson[Keys.PresetName].string else {
                return nil
        }
        
        self.value = value
        
        guard let _ = try! RealmStack.Data.detach().object(ofType: CubeFilter.self, forPrimaryKey: presetName) else {
            return nil
        }
        
        self.presetName = presetName
        
        self.filterChain = {
            
            let presetFilter = try! RealmStack.Data.detach().object(ofType: CubeFilter.self, forPrimaryKey: presetName)!.filter(value)
            
            return presetFilter
        }()
    }
    
    public func toJAYSON() -> JAYSON {
        var d: [String : JAYSON] = [:]
        d[Keys.Value] = JAYSON(value)
        d[Keys.PresetName] = JAYSON(presetName)
        return JAYSON(d)
    }
    
    public let filterChain: FilterChain
    
    // MARK: Private
    
    fileprivate struct Keys {
        static let Value = "value"
        static let PresetName = "presetName"
    }
}
