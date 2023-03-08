//
//  RendererOrientationTests.swift
//  BrightroomEngineTests
//
//  Created by Muukii on 2021/03/30.
//  Copyright © 2021 muukii. All rights reserved.
//

import XCTest

@testable import BrightroomEngine

final class RendererOrientationTests: XCTestCase {

  private func run(image: UIImage, orientation: CGImagePropertyOrientation) throws
    -> BrightRoomImageRenderer.Rendered
  {

    let imageSource = ImageSource(image: image)
    let renderer = BrightRoomImageRenderer(source: imageSource, orientation: orientation)

    let rendered = try renderer.render()
    XCTAssert(rendered.engine == .coreGraphics)
    return rendered
  }

  func testOrientationRight() throws {
    let r = try run(
      image: UIImage(named: "orientation_right.HEIC", in: _pixelengine_bundle, with: nil)!,
      orientation: .right
    )
    let cgImage = r.cgImage
    let uiImage = r.uiImage
    print(cgImage, uiImage)
  }

  func testOrientationDown() throws {
    let r = try run(
      image: UIImage(named: "orientation_down.HEIC", in: _pixelengine_bundle, with: nil)!,
      orientation: .down
    )
    let cgImage = r.cgImage
    let uiImage = r.uiImage
    print(cgImage, uiImage)
  }

  func testOrientationLeft() throws {
    let r = try run(
      image: UIImage(named: "orientation_left.HEIC", in: _pixelengine_bundle, with: nil)!,
      orientation: .left
    )
    let cgImage = r.cgImage
    let uiImage = r.uiImage
    print(cgImage, uiImage)
  }

  func testOrientationUp() throws {
    let r = try run(
      image: UIImage(named: "orientation_up.HEIC", in: _pixelengine_bundle, with: nil)!,
      orientation: .up
    )
    let cgImage = r.cgImage
    let uiImage = r.uiImage
    print(cgImage, uiImage)
  }

  func testOrientationLeftMirrored() throws {
    let r = try run(
      image: UIImage(named: "orientation_left_mirrored.HEIC", in: _pixelengine_bundle, with: nil)!,
      orientation: .leftMirrored
    )
    let cgImage = r.cgImage
    let uiImage = r.uiImage
    print(cgImage, uiImage)
  }

  func testOrientationDownMirrored() throws {
    let r = try run(
      image: UIImage(named: "orientation_down_mirrored.HEIC", in: _pixelengine_bundle, with: nil)!,
      orientation: .downMirrored
    )
    let cgImage = r.cgImage
    let uiImage = r.uiImage
    print(cgImage, uiImage)
  }

  func testOrientationRightMirrored() throws {
    let r = try run(
      image: UIImage(named: "orientation_right_mirrored.HEIC", in: _pixelengine_bundle, with: nil)!,
      orientation: .rightMirrored
    )
    let cgImage = r.cgImage
    let uiImage = r.uiImage
    print(cgImage, uiImage)
  }

  func testOrientationUpMirrored() throws {
    let r = try run(
      image: UIImage(named: "orientation_up_mirrored.HEIC", in: _pixelengine_bundle, with: nil)!,
      orientation: .upMirrored
    )
    let cgImage = r.cgImage
    let uiImage = r.uiImage
    print(cgImage, uiImage)
  }
}
