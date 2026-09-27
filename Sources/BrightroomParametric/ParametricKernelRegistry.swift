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

import CoreImage
import Foundation

/// Provides cached kernels used by the mask renderer.
///
/// Features store semantic parameters only. This registry is renderer
/// infrastructure and all custom operations are represented as Metal-backed
/// Core Image kernels loaded from BrightroomParametric's compiled Metal library.
struct ParametricKernelRegistry: Sendable {

  func makeBrushStamp(
    extent: CGRect,
    center: CGPoint,
    radius: Double,
    hardness: Double,
    opacity: Double
  ) throws -> CIImage {
    guard radius > 0, opacity > 0 else {
      return CIImage.parametricTransparent(extent: extent)
    }

    let kernel = try ParametricMetalKernelStore.colorKernel(named: "brushStamp")
    guard let image = kernel.apply(
      extent: extent,
      arguments: [
        CIVector(x: center.x, y: center.y),
        radius,
        hardness,
        opacity,
      ]
    ) else {
      throw FeatureEvaluationError.imageCreationFailed("brushStamp")
    }
    return image.cropped(to: extent)
  }

  func subtractMask(
    base: CIImage,
    removing: CIImage,
    extent: CGRect
  ) throws -> CIImage {
    let kernel = try ParametricMetalKernelStore.colorKernel(named: "maskSubtract")
    guard let image = kernel.apply(
      extent: extent,
      arguments: [removing, base]
    ) else {
      throw FeatureEvaluationError.imageCreationFailed("maskSubtract")
    }
    return image.cropped(to: extent)
  }
}

private enum ParametricMetalKernelStore {

  /// Loads the bundled compiled Metal library for the parametric kernels.
  ///
  /// `ParametricKernels.metal` is build-compiled into `default.metallib`, then
  /// loaded by function name through `CIColorKernel(functionName:fromMetalLibraryData:)`.
  private static let kernelNames = ["brushStamp", "maskSubtract"]

  static func colorKernel(named name: String) throws -> CIColorKernel {
    switch loadedKernels {
    case let .success(kernels):
      guard let kernel = kernels[name] else {
        throw FeatureEvaluationError.kernelUnavailable(
          name: name,
          reason: "not in the compiled Metal library"
        )
      }
      return kernel
    case let .failure(error):
      throw error
    }
  }

  private static let loadedKernels: Result<[String: CIColorKernel], FeatureEvaluationError> = {
    let data: Data
    do {
      data = try BrushStampMetalLibrary.data()
    } catch {
      return .failure(
        .kernelUnavailable(name: "default.metallib", reason: String(describing: error))
      )
    }
    var result: [String: CIColorKernel] = [:]
    for name in kernelNames {
      do {
        result[name] = try CIColorKernel(functionName: name, fromMetalLibraryData: data)
      } catch {
        return .failure(.kernelUnavailable(name: name, reason: String(describing: error)))
      }
    }
    return .success(result)
  }()
}

extension CIImage {

  static func parametricTransparent(extent: CGRect) -> CIImage {
    CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)
  }

  static func parametricOpaqueWhite(extent: CGRect) -> CIImage {
    CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: extent)
  }
}
