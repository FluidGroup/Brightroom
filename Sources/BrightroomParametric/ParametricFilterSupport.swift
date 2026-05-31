//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import CoreGraphics
import CoreImage
import Foundation

/// Shared constants that mirror Brightroom's legacy filter slider ranges.
///
/// The parametric renderer keeps these values local so the rendering graph can
/// be compiled by a macOS app without importing the UIKit-backed legacy filter
/// types.
enum ParametricFilterConstants {

  /// The maximum legacy slider value for Gaussian blur.
  static let gaussianBlurSliderMax = 100.0

  /// The maximum legacy slider value for unsharp-mask radius.
  static let unsharpMaskRadiusSliderMax = 1.0

  /// The maximum legacy slider value for vignette.
  static let vignetteSliderMax = 2.0
}

/// Converts Brightroom-style normalized radius values into image-domain radii.
enum ParametricRadiusCalculator {

  /// Resolves a slider value against the diagonal length of the current image.
  static func radius(
    value: Double,
    max: Double,
    imageExtent: CGRect
  ) -> Double {
    let base = Double(sqrt(pow(imageExtent.width, 2) + pow(imageExtent.height, 2)))
    let coefficient = base / 20
    return coefficient * value / max
  }
}

/// Geometry helpers kept inside the Parametric layer so the renderer can be
/// compiled without BrightroomEngine's UIKit-backed support files.
enum ParametricImageGeometry {

  /// Translates the image so its extent starts at zero while preserving pixels.
  static func removingExtentOffset(_ image: CIImage) -> CIImage {
    image.transformed(
      by: .init(
        translationX: -image.extent.origin.x,
        y: -image.extent.origin.y
      )
    )
  }
}

/// Creates Core Image color-cube filters from serialized cube data.
enum ParametricColorCubeHelper {

  /// Creates a `CIColorCubeWithColorSpace` filter for a stored RGBA float cube.
  static func makeColorCubeFilter(
    cubeData: Data,
    dimension: Int,
    cacheKey: String?
  ) -> CIFilter {
    if let cacheKey,
       let cached = parametricColorCubeFilterCache.object(forKey: cacheKey as NSString)
    {
      return cached.copy() as! CIFilter
    }

    let expectedByteCount = dimension * dimension * dimension * 4 * MemoryLayout<Float>.size
    precondition(
      cubeData.count == expectedByteCount,
      "Cube data byte count must be \(expectedByteCount), but got \(cubeData.count)."
    )

    let filter = CIFilter(
      name: "CIColorCubeWithColorSpace",
      parameters: [
        "inputCubeDimension": dimension,
        "inputCubeData": cubeData,
        "inputColorSpace": CGColorSpaceCreateDeviceRGB(),
      ]
    )!

    if let cacheKey {
      parametricColorCubeFilterCache.setObject(filter, forKey: cacheKey as NSString)
    }

    return filter
  }
}

nonisolated(unsafe) private let parametricColorCubeFilterCache = NSCache<NSString, CIFilter>()
