//
//  RAWImportTests.swift
//  BrightroomEngineTests
//
//  Created by Muukii on 2021/04/06.
//  Copyright © 2021 muukii. All rights reserved.
//

import Foundation
import XCTest

final class RAWImportTests: XCTestCase {

  func testImport() {

    let url = _url(forResource: "AppleRAW_1", ofType: "DNG")
    let data = try! Data.init(contentsOf: url)

    let image = CIImage(data: data)

    do {
      let filter = CIFilter(imageData: data, options: [:])!
      let image = filter.outputImage!
      print(image)
    }
  }
}
