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

  public static func load() {

    do {

      try autoreleasepool {
        let bundle = Bundle.init(for: _Dummy.self)
        let path = bundle.bundlePath as NSString
        let fileList = try FileManager.default.contentsOfDirectory(atPath: path as String)

        let filters = try fileList
          .filter { $0.hasPrefix("LUT") && $0.hasSuffix(".png") }
          .map { path.appendingPathComponent($0) }
          .map { URL(fileURLWithPath: $0) }
          .map { try Data(contentsOf: $0) }
          .map { UIImage(data: $0)! }
          .map { FilterColorCube.init(lutImage: $0, dimension: 64) }

        self.filters = filters
      }

    } catch {

      assertionFailure("\(error)")
    }
  }
}

fileprivate class _Dummy {}
