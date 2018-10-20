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

  public static func load() {

    do {

      try autoreleasepool {
        let bundle = Bundle.init(for: _Dummy.self)
        let rootPath = bundle.bundlePath as NSString
        let fileList = try FileManager.default.contentsOfDirectory(atPath: rootPath as String)

        let filters = try fileList
          .filter { $0.hasPrefix("LUT") && $0.hasSuffix(".png") }
          .map { path -> FilterColorCube in
            let url = URL(fileURLWithPath: rootPath.appendingPathComponent(path))
            let data = try Data(contentsOf: url)
            let image = UIImage(data: data)!
            return FilterColorCube.init(
              name: path,
              identifier: path,
              lutImage: image,
              dimension: 64
            )
          }
        
        self.filters = filters
      }

    } catch {

      assertionFailure("\(error)")
    }
  }
}

fileprivate class _Dummy {}
