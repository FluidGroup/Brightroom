// Copyright (c) 2026 Hiroshi Kimura (Muukii)

import BrightroomColorAdjustmentKernels
import CoreImage
import Foundation
import os

/// Evaluates measured Whites/Blacks responses in linear Display-P3.
/// Only synthetic-chart responses are stored; no photograph is part of the model.
nonisolated enum TonalPointRecipe {

  /// The two response axes in the resource, in their on-disk order.
  enum Control: Int { case whites, blacks }

  private static let name = "brightroomTonalPoint"
  private static let knots: [Double] = [-100, -50, -25, -10, 0, 10, 25, 50, 100]

  /// One cached amount per control bounds memory during continuous slider edits.
  private struct State {
    var entries: [(amount: Double, table: CIImage)?] = [nil, nil]
  }

  private static let cache = OSAllocatedUnfairLock(initialState: State())

  static func apply(to image: CIImage, control: Control, amount: Double) throws -> CIImage {
    if control == .whites, amount > 0 {
      guard !image.extent.isEmpty else { return image }
      guard !image.extent.isInfinite, image.extent.width.isFinite, image.extent.height.isFinite else {
        throw FeatureEvaluationError.imageCreationFailed("Positive Whites requires a finite analysis extent")
      }
      return try applyAdaptiveWhites(to: image, amount: amount)
    }
    let kernel = try kernel.get()
    let model = try model.get()
    let table = cache.withLock { state in
      if let entry = state.entries[control.rawValue], entry.amount == amount {
        return entry.table
      }
      let table = model.table(control: control, amount: amount)
      // Earlier lazy CI graphs retain their own table when this slot changes.
      state.entries[control.rawValue] = (amount, table)
      return table
    }
    return try ColorAdjustmentKernelSpace.apply(to: image, kernelName: name) { input in
      guard let output = kernel.apply(
        extent: input.extent,
        roiCallback: { index, rect in index == 0 ? rect : table.extent },
        arguments: [input, table, Float(model.dimension)]
      ) else {
        throw FeatureEvaluationError.imageCreationFailed(name)
      }
      return output.cropped(to: input.extent)
    }
  }

  /// Uses the whole input to select the response. Between the two measured
  /// strength ranges the graphs blend in their shared linear working space.
  private static func applyAdaptiveWhites(to image: CIImage, amount: Double) throws -> CIImage {
    try ColorAdjustmentKernelSpace.apply(to: image, kernelName: "brightroomAdaptiveWhites") { input in
      if amount >= 25 { return try StrongWhitesRecipe.apply(to: input, amount: amount) }
      if amount <= 10 { return try moderateWhites(to: input, amount: amount) }
      let moderate = try moderateWhites(to: input, amount: 10)
      let strong = try StrongWhitesRecipe.apply(to: input, amount: 25)
      return moderate.applyingFilter("CIDissolveTransition",
        parameters: [kCIInputTargetImageKey: strong, kCIInputTimeKey: (amount - 10) / 15]).cropped(to: input.extent)
    }
  }

  private static func moderateWhites(to input: CIImage, amount: Double) throws -> CIImage {
    let kernels = try adaptiveKernels.get()
    let table = try positiveTable.get()
    guard let luminance = kernels.luminance.apply(extent: input.extent, arguments: [input]) else {
      throw FeatureEvaluationError.imageCreationFailed("Whites luminance")
    }
    // This is an image statistic, so the radius follows this feature's input
    // extent, including crops upstream, and scales with a reduced preview.
    let radius = max(input.extent.width, input.extent.height) / 256
    let blurred = luminance.clampedToExtent().applyingFilter("CIGaussianBlur",
      parameters: [kCIInputRadiusKey: radius]).cropped(to: input.extent)
    guard let moments = kernels.moments.apply(extent: input.extent, arguments: [blurred, input]) else {
      throw FeatureEvaluationError.imageCreationFailed("Whites moments")
    }
    let average = moments.applyingFilter("CIAreaAverage",
      parameters: [kCIInputExtentKey: CIVector(cgRect: input.extent)])
    guard let result = kernels.response.apply(extent: input.extent,
      roiCallback: { index, rect in
        switch index {
        case 0: rect
        case 1: table.extent
        default: average.extent
        }
      }, arguments: [input, table, average, Float(amount), Float(32)]) else {
      throw FeatureEvaluationError.imageCreationFailed("brightroomAdaptiveWhites")
    }
    return result.cropped(to: input.extent)
  }

  private struct AdaptiveKernels {
    let luminance: CIColorKernel
    let moments: CIColorKernel
    let response: CIKernel
  }

  private static let adaptiveKernels: Result<AdaptiveKernels, FeatureEvaluationError> = {
    do {
      let data = try ColorAdjustmentMetalLibrary.data()
      return .success(AdaptiveKernels(
        luminance: try CIColorKernel(functionName: "brightroomWhitesLuminance", fromMetalLibraryData: data),
        moments: try CIColorKernel(functionName: "brightroomWhitesMoments", fromMetalLibraryData: data),
        response: try CIKernel(functionName: "brightroomAdaptiveWhites", fromMetalLibraryData: data)))
    } catch {
      return .failure(.kernelUnavailable(name: "brightroomAdaptiveWhites", reason: String(describing: error)))
    }
  }()

  /// Five positive strengths share one 32 x 5120 atlas (below the 8192 limit
  /// on supported Intel Macs). Earlier graphs retain this immutable image.
  private static let positiveTable: Result<CIImage, FeatureEvaluationError> = model.map { model in
    model.positiveTable()
  }

  /// Immutable linear-P3 deltas on an encoded-P3 lattice at nine signed strengths.
  private struct Model {
    let dimension: Int
    let samples: [Float]

    func positiveTable() -> CIImage {
      let count = dimension * dimension * dimension
      let height = 5 * dimension * dimension
      var pixels = [Float](repeating: 0, count: 5 * count * 4)
      for strength in 0..<5 {
        for node in 0..<count {
          let row = strength * dimension * dimension + node / dimension
          let destination = ((height - 1 - row) * dimension + node % dimension) * 4
          let source = ((strength + 4) * count + node) * 3
          for channel in 0..<3 {
            pixels[destination + channel] = samples[source + channel]
          }
          pixels[destination + 3] = 1
        }
      }
      return CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) },
        bytesPerRow: dimension * 4 * MemoryLayout<Float>.stride,
        size: CGSize(width: dimension, height: height), format: .RGBAf, colorSpace: nil)
    }

    func table(control: Control, amount: Double) -> CIImage {
      let count = dimension * dimension * dimension
      let upper = knots.firstIndex { $0 > amount } ?? (knots.count - 1)
      let lower = upper - 1
      let fraction = Float((amount - knots[lower]) / (knots[upper] - knots[lower]))
      let first = (control.rawValue * knots.count + lower) * count * 3
      let second = first + count * 3
      var pixels = [Float](repeating: 0, count: count * 4)
      for node in 0..<count {
        // Bitmap rows run top-to-bottom; the kernel atlas runs bottom-to-top.
        // Lattice nodes are R-fastest, then G, then B.
        let row = node / dimension
        let destination = ((dimension * dimension - 1 - row) * dimension + node % dimension) * 4
        for channel in 0..<3 {
          let offset = node * 3 + channel
          pixels[destination + channel] =
            samples[first + offset] * (1 - fraction) + samples[second + offset] * fraction
        }
        pixels[destination + 3] = 1
      }
      return CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) },
        bytesPerRow: dimension * 4 * MemoryLayout<Float>.stride,
        size: CGSize(width: dimension, height: dimension * dimension),
        format: .RGBAf, colorSpace: nil)
    }
  }

  private static let kernel: Result<CIKernel, FeatureEvaluationError> = {
    do {
      return .success(try CIKernel(functionName: name,
        fromMetalLibraryData: ColorAdjustmentMetalLibrary.data()))
    } catch {
      return .failure(.kernelUnavailable(name: name, reason: String(describing: error)))
    }
  }()

  private static let model: Result<Model, FeatureEvaluationError> = {
    do {
      guard let url = Bundle.module.url(forResource: "TonalPointCalibration", withExtension: "lzfse") else {
        throw FeatureEvaluationError.imageCreationFailed("Missing tonal-point calibration")
      }
      let compressed = try Data(contentsOf: url) as NSData
      let data = try compressed.decompressed(using: .lzfse) as Data
      let dimension = 32
      let count = 2 * knots.count * dimension * dimension * dimension * 3
      guard data.count == 12 + count * 4, data.prefix(8) == Data("BRTN0001".utf8),
        data.withUnsafeBytes({ $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian }) == dimension
      else {
        throw FeatureEvaluationError.imageCreationFailed("Invalid tonal-point calibration layout")
      }
      // Float32 avoids another quantization of measured deltas and is available
      // on Intel Macs as well as Apple silicon. The resource is losslessly packed.
      let samples = data.withUnsafeBytes { bytes in
        (0..<count).map { index in
          Float(bitPattern: bytes.loadUnaligned(fromByteOffset: 12 + index * 4, as: UInt32.self).littleEndian)
        }
      }
      guard samples.allSatisfy({ $0.isFinite }) else {
        throw FeatureEvaluationError.imageCreationFailed("Nonfinite tonal-point calibration")
      }
      return .success(Model(dimension: dimension, samples: samples))
    } catch let error as FeatureEvaluationError {
      return .failure(error)
    } catch {
      return .failure(.imageCreationFailed("Tonal-point calibration: \(error)"))
    }
  }()
}
