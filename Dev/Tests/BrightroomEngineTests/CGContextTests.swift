//
//  CGContextTests.swift
//  BrightroomEngineTests
//
//  Created by Muukii on 2021/04/01.
//  Copyright © 2021 muukii. All rights reserved.
//

import Foundation
import XCTest

@testable import BrightroomEngine

final class CGContextTests: XCTestCase {

  func test_createContext_PNG_16bpc_P3() {

    let image = UIImage(named: "screenshot-16bit-p3-alpha.png", in: _pixelengine_bundle, with: nil)!

    do {
      _ = try CGContext.makeContext(for: image.cgImage!)
    } catch {
      XCTFail(error.localizedDescription)
    }

    let result = ImageTool.makeResizedCGImage(from: image.cgImage!, maxPixelSize: 300)
    XCTAssertNotEqual(result, nil)
  }

  func test_createContext_PNG_8bpc_P3() {

    let image = UIImage(named: "screenshot-8bit-p3-alpha.png", in: _pixelengine_bundle, with: nil)!

    do {
      _ = try CGContext.makeContext(for: image.cgImage!)
    } catch {
      XCTFail(error.localizedDescription)
    }
  }

  func test_resize_PNG_8bpc_lcd() {

    let image = UIImage(named: "screenshot-8bit-lcd.png", in: _pixelengine_bundle, with: nil)!

    do {
      _ = try CGContext.makeContext(for: image.cgImage!)
    } catch {
      XCTFail(error.localizedDescription)
    }
  }


}
