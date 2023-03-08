//
//  RAWImportTests.swift
//  BrightroomEngineTests
//
//  Created by Muukii on 2021/04/06.
//  Copyright © 2021 muukii. All rights reserved.
//

import Foundation
import XCTest

@testable import BrightroomEngine

final class RAWImportTests: XCTestCase {

  func testImport() {

    // simulator does not work well

    let url = _url(forResource: "AppleRAW_1", ofType: "DNG")
    let data = try! Data.init(contentsOf: url)


    do {
      let filter = CIFilter(imageData: data, options: [:])!
      let image = filter.outputImage
    }
  }

  func testLoadOrientationFromURL() {

    let url = _url(forResource: "AppleRAW_1", ofType: "DNG")

    let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
    let value = ImageTool.readOrientation(from: source)

    XCTAssertNotNil(value)
    XCTAssertEqual(value, .right)

  }

  func testLoadOrientationFromData() {

    let url = _url(forResource: "AppleRAW_1", ofType: "DNG")
    let data = try! Data.init(contentsOf: url)

    let source = CGImageSourceCreateWithData(data as CFData, nil)!
    let value = ImageTool.readOrientation(from: source)

    XCTAssertNotNil(value)
    XCTAssertEqual(value, .right)

  }
}
