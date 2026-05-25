import CoreImage
import BrightroomEngine
import IOSurface
import MetalKit
import os
import simd
import SwiftUI
import UIKit

extension CGSize {
  var simdFloat2: SIMD2<Float> {
    SIMD2(Float(width), Float(height))
  }
}

extension CGFloat {
  var logString: String {
    String(format: "%.2f", Double(self))
  }
}

extension Double {
  var logString: String {
    String(format: "%.2f", self)
  }
}

extension CGRect {
  var logDescription: String {
    "x:\(minX.logString) y:\(minY.logString) w:\(width.logString) h:\(height.logString)"
  }
}

enum EditingCanvasImageProcessing {
  static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

  static func clippedToSourceAlpha(_ image: CIImage, source: CIImage) -> CIImage {
    let extent = image.extent
    guard extent.isEmpty == false, extent.isNull == false else {
      return image
    }

    let sourceAlphaMask = source
      .cropped(to: extent)
      .applyingFilter(
        "CIColorMatrix",
        parameters: [
          "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1),
          "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
          "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1),
          "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ]
      )
      .cropped(to: extent)

    let clearBackground = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
      .cropped(to: extent)

    return image
      .applyingFilter(
        "CIBlendWithAlphaMask",
        parameters: [
          kCIInputBackgroundImageKey: clearBackground,
          kCIInputMaskImageKey: sourceAlphaMask,
        ]
      )
      .cropped(to: extent)
  }
}

extension CGPoint {
  var simdFloat2: SIMD2<Float> {
    SIMD2(Float(x), Float(y))
  }

  func distance(to point: CGPoint) -> CGFloat {
    hypot(x - point.x, y - point.y)
  }

  func midpoint(to point: CGPoint) -> CGPoint {
    CGPoint(
      x: (x + point.x) / 2,
      y: (y + point.y) / 2
    )
  }

  func interpolate(to point: CGPoint, progress: CGFloat) -> CGPoint {
    CGPoint(
      x: x + (point.x - x) * progress,
      y: y + (point.y - y) * progress
    )
  }
}
