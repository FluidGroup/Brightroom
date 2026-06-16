//
//  RAWImportTests.swift
//  BrightroomEngineTests
//
//  Created by Muukii on 2021/04/06.
//  Copyright © 2021 muukii. All rights reserved.
//

import CoreImage
import Foundation
import ImageIO
import Testing

@testable import BrightroomEngine

struct RAWImportTests {

  @Test func `import`() {

    // simulator does not work well

    let url = _url(forResource: "AppleRAW_1", ofType: "DNG")
    let data = try! Data.init(contentsOf: url)


    do {
      let filter = CIFilter(imageData: data, options: [:])!
      let image = filter.outputImage
    }
  }

  @Test func `Load orientation from URL`() {

    let url = _url(forResource: "AppleRAW_1", ofType: "DNG")

    let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
    let value = ImageTool.readOrientation(from: source)

    #expect(value != nil)
    #expect(value == .right)

  }

  @Test func `Load orientation from data`() {

    let url = _url(forResource: "AppleRAW_1", ofType: "DNG")
    let data = try! Data.init(contentsOf: url)

    let source = CGImageSourceCreateWithData(data as CFData, nil)!
    let value = ImageTool.readOrientation(from: source)

    #expect(value != nil)
    #expect(value == .right)

  }
}
