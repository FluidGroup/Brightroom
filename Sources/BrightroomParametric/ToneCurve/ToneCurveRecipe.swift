//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import BrightroomColorAdjustmentKernels
import CoreImage
import Foundation
import os

/// Applies one immutable Tone Curve plan to a Core Image recipe.
///
/// The sampled table is a non-color `.RGf` image. Its first 4,096 pixels store
/// Y/Red and its second 4,096 pixels store Green/Blue. Keeping all four curves
/// in one row avoids both Core Image alpha semantics and vertical interpolation
/// between logically independent channels.
nonisolated enum ToneCurveRecipe {

  /// Returns the original image exactly when the authored value is an identity.
  static func apply(
    to image: CIImage,
    curves: ToneCurveFeature.Curves
  ) throws -> CIImage {
    guard let plan = ToneCurveRenderPlan(curves: curves) else {
      return image
    }
    return try apply(to: image, plan: plan)
  }

  /// Applies a previously compiled plan without rebuilding its sample table.
  ///
  /// The kernel computes in extended-linear Display-P3 whatever the
  /// rendering context's working space is (`ColorAdjustmentKernelSpace`).
  static func apply(
    to image: CIImage,
    plan: ToneCurveRenderPlan
  ) throws -> CIImage {
    try ColorAdjustmentKernelSpace.apply(
      to: image,
      kernelName: ToneCurveKernelStore.name
    ) { image in
      try applyKernel(to: image, plan: plan)
    }
  }

  /// Runs the kernel on the image's working-space values as they are, with
  /// no color-space match. Use `apply(to:plan:)`; tests call this to show
  /// that the match changes nothing in an extended-linear Display-P3 context.
  static func applyKernel(
    to image: CIImage,
    plan: ToneCurveRenderPlan
  ) throws -> CIImage {
    let kernel = try ToneCurveKernelStore.kernel()
    let table = ToneCurveTableImageCache.shared.image(for: plan)
    guard
      let output = kernel.apply(
        extent: image.extent,
        roiCallback: { inputIndex, destinationRect in
          switch inputIndex {
          case 0:
            destinationRect
          case 1:
            table.extent
          default:
            .null
          }
        },
        arguments: [
          image,
          table,
          vector(plan.lowerOutputs),
          vector(plan.upperOutputs),
          vector(plan.lowerTangents),
          vector(plan.upperTangents),
          vector(plan.activeChannels),
        ]
      )
    else {
      throw FeatureEvaluationError.imageCreationFailed(ToneCurveKernelStore.name)
    }
    return output.cropped(to: image.extent)
  }

  private static func vector(_ value: SIMD4<Float>) -> CIVector {
    CIVector(
      x: CGFloat(value.x),
      y: CGFloat(value.y),
      z: CGFloat(value.z),
      w: CGFloat(value.w)
    )
  }
}

/// Retains the sampled CIImage for the most recently requested curve value.
///
/// Core Image recipes retain an image after it leaves this one-entry cache, so
/// replacing the entry cannot invalidate an in-flight frame. Interactive edits
/// normally advance one value at a time, making a single entry sufficient to
/// prevent per-frame table allocation without growing an unbounded cache.
private nonisolated final class ToneCurveTableImageCache: Sendable {

  struct Entry: @unchecked Sendable {
    let identity: ToneCurveFeature.RenderKey
    let image: CIImage
  }

  static let shared = ToneCurveTableImageCache()

  private let storage = OSAllocatedUnfairLock<Entry?>(initialState: nil)

  func image(for plan: ToneCurveRenderPlan) -> CIImage {
    storage.withLock { entry in
      if let entry, entry.identity == plan.identity {
        return entry.image
      }

      let tableWidth = ToneCurveRenderPlan.sampleCount * 2
      let image = CIImage(
        bitmapData: plan.sampleTable.combinedData(),
        bytesPerRow: tableWidth * MemoryLayout<SIMD2<Float>>.stride,
        size: CGSize(width: tableWidth, height: 1),
        format: .RGf,
        colorSpace: nil
      )
      .samplingLinear()
      entry = Entry(identity: plan.identity, image: image)
      return image
    }
  }
}

/// Loads the general Core Image kernel from the package's compiled Metal library once.
private nonisolated enum ToneCurveKernelStore {

  static let name = "brightroomToneCurve"

  static func kernel() throws -> CIKernel {
    switch loadedKernel {
    case .success(let kernel):
      kernel
    case .failure(let error):
      throw error
    }
  }

  private static let loadedKernel: Result<CIKernel, FeatureEvaluationError> = {
    do {
      let data = try ColorAdjustmentMetalLibrary.data()
      return .success(
        try CIKernel(
          functionName: name,
          fromMetalLibraryData: data
        )
      )
    } catch {
      return .failure(.kernelUnavailable(name: name, reason: String(describing: error)))
    }
  }()
}
