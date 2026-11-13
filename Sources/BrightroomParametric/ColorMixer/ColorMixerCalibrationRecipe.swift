// Copyright (c) 2026 Hiroshi Kimura (Muukii)

import BrightroomColorAdjustmentKernels
import CoreImage
import Foundation
import os

/// Compiles the measured selection weights and parameter responses into three RGB delta tables.
///
/// The resource contains only analytic-chart measurements. Authored band values
/// select the response; no photograph or A10-specific correction is stored.
nonisolated enum ColorMixerCalibrationRecipe {

  static let name = "brightroomCalibratedColorMixer"

  private struct State {
    var entry: (plan: ColorMixerRenderPlan, tables: [CIImage])?
  }

  // Retain one compiled edit, not every intermediate slider value. Existing CI
  // graphs retain their own images when another edit replaces this cache entry.
  private static let cache = OSAllocatedUnfairLock(initialState: State())

  private static let kernel: Result<CIKernel, FeatureEvaluationError> = {
    do {
      return .success(try CIKernel(functionName: name,
        fromMetalLibraryData: ColorAdjustmentMetalLibrary.data()))
    } catch {
      return .failure(.kernelUnavailable(name: name, reason: String(describing: error)))
    }
  }()

  /// Runs on linear Display-P3 pixels; the caller owns the working-space match.
  static func applyKernel(to image: CIImage, plan: ColorMixerRenderPlan) throws -> CIImage {
    let kernel = try kernel.get()
    let model = try model.get()
    let tables = cache.withLock { state in
      if let entry = state.entry, entry.plan == plan {
        return entry.tables
      }
      let tables = model.tables(for: plan)
      state.entry = (plan, tables)
      return tables
    }
    guard let output = kernel.apply(
      extent: image.extent,
      roiCallback: { index, rect in
        if index == 0 { return rect }
        return tables[Int(index) - 1].extent
      },
      arguments: [image, tables[0], tables[1], tables[2], Float(model.dimension)]
    ) else {
      throw FeatureEvaluationError.imageCreationFailed(name)
    }
    return output.cropped(to: image.extent)
  }

  /// Immutable calibration data: H/S/L axes, eight bands, two signs, and nine response knots.
  private struct Model {

    let dimension: Int
    let samples: [Float]

    /// Combines band selections before sampling a response, in L/S/H order.
    func tables(for plan: ColorMixerRenderPlan) -> [CIImage] {
      let count = dimension * dimension * dimension
      let responseOffset = 3 * 8 * 2 * count
      let corrections = [
        (0..<8).map { Float(plan.hue(at: $0)) },
        (0..<8).map { Float(plan.saturation(at: $0)) },
        (0..<8).map { Float(plan.luminance(at: $0)) },
      ]
      return [2, 1, 0].map { axis in
        var pixels = [Float](repeating: 0, count: count * 4)
        for node in 0..<count {
          var amount: Float = 0
          for band in 0..<8 {
            let correction = corrections[axis][band]
            let sign: Int
            if correction < 0 { sign = 0 } else { sign = 1 }
            let weight = samples[((axis * 8 + band) * 2 + sign) * count + node]
            amount += weight * correction
          }
          let position = min(max((amount + 1) * 4, 0), 8)
          let lower = min(Int(position), 7)
          let fraction = position - Float(lower)
          let first = responseOffset + ((axis * 9 + lower) * count + node) * 3
          let second = first + count * 3
          // CIImage bitmap scanlines start at the top; the kernel's atlas rows
          // start at the bottom. The node layout is R-fastest, then G, then B.
          let row = node / dimension
          let destination = ((dimension * dimension - 1 - row) * dimension + node % dimension) * 4
          for channel in 0..<3 {
            pixels[destination + channel] =
              samples[first + channel] * (1 - fraction) + samples[second + channel] * fraction
          }
          pixels[destination + 3] = 1
        }
        return CIImage(
          bitmapData: pixels.withUnsafeBytes { Data($0) },
          bytesPerRow: dimension * 4 * MemoryLayout<Float>.stride,
          size: CGSize(width: dimension, height: dimension * dimension),
          format: .RGBAf,
          colorSpace: nil
        )
      }
    }
  }

  private static let model: Result<Model, FeatureEvaluationError> = {
    do {
      guard let url = Bundle.module.url(forResource: "ColorMixerCalibration", withExtension: "lzfse") else {
        throw FeatureEvaluationError.imageCreationFailed("Missing Color Mixer calibration")
      }
      let compressed = try Data(contentsOf: url) as NSData
      let data = try compressed.decompressed(using: .lzfse) as Data
      let dimension = 24
      let count = (3 * 8 * 2 + 3 * 9 * 3) * dimension * dimension * dimension
      guard data.count == 12 + count * 2, data.prefix(8) == Data("BRCM0001".utf8),
        data.withUnsafeBytes({ $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian }) == dimension
      else {
        throw FeatureEvaluationError.imageCreationFailed("Invalid Color Mixer calibration layout")
      }
      let samples = data.withUnsafeBytes { bytes in
        (0..<count).map { index in
          // Swift's Float16 arithmetic is unavailable on Intel macOS. Decode
          // its IEEE storage directly so both supported Mac architectures read
          // exactly the same model, including subnormal response deltas.
          let bits = bytes.loadUnaligned(fromByteOffset: 12 + index * 2, as: UInt16.self).littleEndian
          let sign = UInt32(bits & 0x8000) << 16
          let exponent = UInt32((bits >> 10) & 0x1f)
          let fraction = UInt32(bits & 0x3ff)
          if exponent == 0 {
            let magnitude = Float(fraction) / 16_777_216
            return Float(bitPattern: magnitude.bitPattern | sign)
          }
          if exponent == 31 {
            return Float(bitPattern: sign | 0x7f800000 | (fraction << 13))
          }
          return Float(bitPattern: sign | ((exponent + 112) << 23) | (fraction << 13))
        }
      }
      guard samples.allSatisfy(\.isFinite) else {
        throw FeatureEvaluationError.imageCreationFailed("Nonfinite Color Mixer calibration")
      }
      return .success(Model(dimension: dimension, samples: samples))
    } catch let error as FeatureEvaluationError {
      return .failure(error)
    } catch {
      return .failure(.imageCreationFailed("Color Mixer calibration: \(error)"))
    }
  }()
}
