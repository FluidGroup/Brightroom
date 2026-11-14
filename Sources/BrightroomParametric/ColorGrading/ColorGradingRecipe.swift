// Copyright (c) 2026 Hiroshi Kimura (Muukii)

import BrightroomColorAdjustmentKernels
import CoreImage
import Foundation
import os

/// Compiles the authored grading into three channel curves and evaluates one pass.
nonisolated enum ColorGradingRecipe {

  private static let name = "brightroomColorGrading"

  private static let kernel: Result<CIKernel, FeatureEvaluationError> = {
    do {
      return .success(try CIKernel(functionName: name,
        fromMetalLibraryData: ColorAdjustmentMetalLibrary.data()))
    } catch {
      return .failure(.kernelUnavailable(name: name, reason: String(describing: error)))
    }
  }()

  /// A single retained value avoids rebuilding the table for every preview frame.
  /// Recipes retain their table when a subsequent edit replaces this entry.
  private static let tableCache = OSAllocatedUnfairLock<(ColorGradingFeature, CIImage)?>(initialState: nil)

  static func apply(to image: CIImage, grading: ColorGradingFeature) throws -> CIImage {
    let kernel = try kernel.get()
    let hasLocalCorrection = !grading.shadows.isIdentity || !grading.midtones.isIdentity || !grading.highlights.isIdentity
    let table = try tableCache.withLock { entry in
      if let entry, entry.0 == grading { return entry.1 }
      let samples = try ColorGradingCurves.samples(for: grading)
      // Three separate Rf rows within one horizontal strip avoid color and
      // premultiplied-alpha interpretation of numeric table values.
      let width = samples.count
      let table = CIImage(
        bitmapData: samples.withUnsafeBytes { Data($0) },
        bytesPerRow: width * MemoryLayout<Float>.stride,
        size: CGSize(width: width, height: 1), format: .Rf, colorSpace: nil
      ).samplingLinear()
      entry = (grading, table)
      return table
    }
    let tint = ColorGradingCurves.globalTint(grading.global)
    return try ColorAdjustmentKernelSpace.apply(to: image, kernelName: name) { input in
      guard let output = kernel.apply(
        extent: input.extent,
        roiCallback: { index, rect in index == 0 ? rect : table.extent },
        arguments: [input, table, hasLocalCorrection ? 1.0 : 0.0,
          CIVector(x: tint[0], y: tint[1], z: tint[2]), 0.24 * grading.global.luminance / 100]
      ) else { throw FeatureEvaluationError.imageCreationFailed(name) }
      return output.cropped(to: image.extent)
    }
  }
}
