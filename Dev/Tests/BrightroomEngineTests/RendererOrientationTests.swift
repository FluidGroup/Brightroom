//
//  RendererOrientationTests.swift
//  BrightroomEngineTests
//
//  Created by Muukii on 2021/03/30.
//  Copyright © 2021 muukii. All rights reserved.
//

import Foundation
import ImageIO
import Testing
import UIKit

@testable import BrightroomEngine

struct RendererOrientationTests {

  private func run(image: UIImage, orientation: CGImagePropertyOrientation) async throws
    -> BrightRoomImageRenderer.Rendered
  {

    let imageSource = ImageSource(image: image)
    let renderer = BrightRoomImageRenderer(source: imageSource, orientation: orientation)

    let rendered = try await renderer.render()
    return rendered
  }

  @Test func orientationRight() async throws {
    let r = try await run(
      image: UIImage(named: "orientation_right.HEIC", in: _pixelengine_bundle, with: nil)!,
      orientation: .right
    )
    let cgImage = try r.cgImage
    let uiImage = try r.uiImage
    print(cgImage, uiImage)
  }

  @Test func orientationDown() async throws {
    let r = try await run(
      image: UIImage(named: "orientation_down.HEIC", in: _pixelengine_bundle, with: nil)!,
      orientation: .down
    )
    let cgImage = try r.cgImage
    let uiImage = try r.uiImage
    print(cgImage, uiImage)
  }

  @Test func orientationLeft() async throws {
    let r = try await run(
      image: UIImage(named: "orientation_left.HEIC", in: _pixelengine_bundle, with: nil)!,
      orientation: .left
    )
    let cgImage = try r.cgImage
    let uiImage = try r.uiImage
    print(cgImage, uiImage)
  }

  @Test func orientationUp() async throws {
    let r = try await run(
      image: UIImage(named: "orientation_up.HEIC", in: _pixelengine_bundle, with: nil)!,
      orientation: .up
    )
    let cgImage = try r.cgImage
    let uiImage = try r.uiImage
    print(cgImage, uiImage)
  }

  @Test func `orientation left mirrored`() async throws {
    let r = try await run(
      image: UIImage(named: "orientation_left_mirrored.HEIC", in: _pixelengine_bundle, with: nil)!,
      orientation: .leftMirrored
    )
    let cgImage = try r.cgImage
    let uiImage = try r.uiImage
    print(cgImage, uiImage)
  }

  @Test func `orientation down mirrored`() async throws {
    let r = try await run(
      image: UIImage(named: "orientation_down_mirrored.HEIC", in: _pixelengine_bundle, with: nil)!,
      orientation: .downMirrored
    )
    let cgImage = try r.cgImage
    let uiImage = try r.uiImage
    print(cgImage, uiImage)
  }

  @Test func `orientation right mirrored`() async throws {
    let r = try await run(
      image: UIImage(named: "orientation_right_mirrored.HEIC", in: _pixelengine_bundle, with: nil)!,
      orientation: .rightMirrored
    )
    let cgImage = try r.cgImage
    let uiImage = try r.uiImage
    print(cgImage, uiImage)
  }

  @Test func `orientation up mirrored`() async throws {
    let r = try await run(
      image: UIImage(named: "orientation_up_mirrored.HEIC", in: _pixelengine_bundle, with: nil)!,
      orientation: .upMirrored
    )
    let cgImage = try r.cgImage
    let uiImage = try r.uiImage
    print(cgImage, uiImage)
  }
}
