//
//  ColorCubeStorage.swift
//  PixelEditor
//
//  Created by muukii on 10/17/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

import PixelEngine

public enum ColorCubeStorage {

  public static var filters: [FilterColorCube] = []
  
  public static func load(filters: [FilterColorCube]) {
    self.filters = filters
  }
}

fileprivate class _Dummy {}
