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

  @Test func `A RAW image is developed once, at creation`() throws {
    let url = _url(forResource: "AppleRAW_1", ofType: "DNG")
    let fromFile = try SourceImage(rawContentsOf: url)
    let fromData = try SourceImage(rawData: Data(contentsOf: url))

    // Developed pixels are already oriented: the stored `.right` turns the
    // developed image portrait, and no orientation is left to apply.
    #expect(fromFile.storage.orientation == .up)
    #expect(fromFile.pixelSize == fromData.pixelSize)
    #expect(fromFile.pixelSize.height > fromFile.pixelSize.width)
    guard case .bitmap = fromFile.storage.backing else {
      Issue.record("A RAW image keeps its developed bitmap.")
      return
    }
    #expect(fromFile.makeCIImage().extent == CGRect(origin: .zero, size: fromFile.pixelSize))
  }
}
