//
//  PixelEngineTests.swift
//  PixelEngineTests
//
//  Created by Muukii on 2021/03/10.
//  Copyright © 2021 muukii. All rights reserved.
//

import XCTest

@testable import BrightroomEngine

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
     
  func testScalingCGSize() {
    
    do {
      let size = CGSize(width: 5561, height: 3127)
      
      let scaled = size.scaled(maxPixelSize: 300)
      
      XCTAssertEqual(scaled, CGSize(width: 300, height: 169))
    }
    
    do {
      let size = CGSize(width: 3127, height: 5561)
      
      let scaled = size.scaled(maxPixelSize: 300)
      
      XCTAssertEqual(scaled, CGSize(width: 169, height: 300))
    }
    
  }
}
