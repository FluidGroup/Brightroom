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

enum MetalBrushSandboxImageProcessing {
  static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
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
