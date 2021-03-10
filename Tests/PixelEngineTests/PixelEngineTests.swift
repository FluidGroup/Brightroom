//
//  PixelEngineTests.swift
//  PixelEngineTests
//
//  Created by Muukii on 2021/03/10.
//  Copyright © 2021 muukii. All rights reserved.
//

import XCTest

@testable import PixelEngine

class PixelEngineTests: XCTestCase {
  override func setUpWithError() throws {
    // Put setup code here. This method is called before the invocation of each test method in the class.

    // In UI tests it is usually best to stop immediately when a failure occurs.
    continueAfterFailure = false

    // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
  }

  override func tearDownWithError() throws {
    // Put teardown code here. This method is called after the invocation of each test method in the class.
  }
  
  func testHoge() {
    
    let crop = EditingCrop(
      imageSize: .init(width: 1280, height: 1280),
      cropRect: .init(
        origin: .init(x: 80, y: 80),
        size: .init(width: 100, height: 100)
      )
    )
    
    let scaled = crop.scaled(toWidth: 300)
        
    XCTAssertEqual(crop, scaled.restoreFromScaled())
    
  }
}
