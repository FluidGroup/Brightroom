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

/// Provides cached kernels used by the parametric Core Image compiler.
///
/// Documents store semantic feature data only. This registry is renderer
/// infrastructure and all custom operations are represented as Metal-backed
/// Core Image kernels. The backing source can evolve from inlined Metal source
/// to compiled metallib resources without changing document Codable shape.
public struct ParametricKernelRegistry: Sendable {

  /// Creates a registry for Metal-backed parametric kernels.
  public init() {}

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
      throw ParametricKernelRegistryError.failedToApplyKernel("brushStamp")
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
      throw ParametricKernelRegistryError.failedToApplyKernel("maskSubtract")
    }
    return image.cropped(to: extent)
  }
}

/// Errors thrown while preparing or applying parametric custom kernels.
public enum ParametricKernelRegistryError: Error, Equatable, Sendable {

  /// A named kernel was not present in the loaded Metal source.
  case missingKernel(String)

  /// Core Image returned nil while applying a named kernel.
  case failedToApplyKernel(String)

  /// Core Image failed to compile the Metal source.
  case failedToCompileMetalSource(String)
}

private enum ParametricMetalKernelStore {

  static func colorKernel(named name: String) throws -> CIColorKernel {
    switch loadedKernels {
    case let .success(kernels):
      guard let kernel = kernels[name] else {
        throw ParametricKernelRegistryError.missingKernel(name)
      }
      return kernel
    case let .failure(error):
      throw error
    }
  }

  private static let loadedKernels: Result<[String: CIColorKernel], ParametricKernelRegistryError> = {
    do {
      let kernels = try CIKernel.kernels(withMetalString: metalSource)
      var result: [String: CIColorKernel] = [:]
      for kernel in kernels {
        if let colorKernel = kernel as? CIColorKernel {
          result[kernel.name] = colorKernel
        }
      }
      return .success(result)
    } catch {
      return .failure(.failedToCompileMetalSource(String(describing: error)))
    }
  }()

  private static let metalSource = """
  #include <CoreImage/CoreImage.h>
  using namespace metal;

  extern "C" { namespace coreimage {
    [[ stitchable ]] float4 brushStamp(
      float2 center,
      float radius,
      float hardness,
      float opacity,
      destination dest
    ) {
      if (radius <= 0.0 || opacity <= 0.0) {
        return float4(0.0);
      }

      float distanceFromCenter = length(dest.coord() - center);
      if (distanceFromCenter > radius) {
        return float4(0.0);
      }

      float normalizedDistance = distanceFromCenter / radius;
      float alpha = 1.0;
      if (hardness < 0.999) {
        float start = clamp(hardness, 0.0, 0.998);
        alpha = 1.0 - smoothstep(start, 1.0, normalizedDistance);
      }

      alpha *= clamp(opacity, 0.0, 1.0);
      return float4(alpha, alpha, alpha, alpha);
    }

    [[ stitchable ]] float4 maskSubtract(sample_t removing, sample_t base) {
      float alpha = max(base.a - removing.a, 0.0);
      return float4(alpha, alpha, alpha, alpha);
    }
  }}
  """
}

extension CIImage {

  static func parametricTransparent(extent: CGRect) -> CIImage {
    CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)
  }

  static func parametricOpaqueWhite(extent: CGRect) -> CIImage {
    CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: extent)
  }
}
