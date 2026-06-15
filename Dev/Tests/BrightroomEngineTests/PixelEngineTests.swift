//
//  PixelEngineTests.swift
//  PixelEngineTests
//
//  Created by Muukii on 2021/03/10.
//  Copyright © 2021 muukii. All rights reserved.
//

import Testing
import Foundation
import CoreGraphics

@testable import BrightroomEngine

struct PixelEngineTests {
  @Test func `Scaling CGSize`() throws {

    do {
      let size = CGSize(width: 5561, height: 3127)

      let scaled = size.scaled(maxPixelSize: 300)

      try #require(scaled == CGSize(width: 300, height: 169))
    }

    do {
      let size = CGSize(width: 3127, height: 5561)

      let scaled = size.scaled(maxPixelSize: 300)

      try #require(scaled == CGSize(width: 169, height: 300))
    }

  }
}
