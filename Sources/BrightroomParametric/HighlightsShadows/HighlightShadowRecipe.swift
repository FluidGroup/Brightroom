// Copyright (c) 2026 Hiroshi Kimura (Muukii)

import BrightroomColorAdjustmentKernels
import CoreImage
import Foundation

/// Builds a lazy, spatial tonal response from measured scene and color changes.
/// Image statistics and neighborhood guides remain on the GPU. The immutable
/// calibration describes the response, never an image or an authored edit.
nonisolated enum HighlightShadowRecipe {

  static func apply(to image: CIImage, highlights: Bool, value: Double) throws -> CIImage {
    guard value.isFinite, value != 0 else { return image }
    // Clamp before unit conversion so very large finite values cannot overflow
    // into a nonfinite amount and accidentally become neutral.
    let amount = min(max(value, -1), 1) * (highlights ? -100 : 100)
    let control = (highlights ? 0 : 2) + (amount > 0 ? 1 : 0)
    let calibration = try calibration.get()
    let kernels = try kernels.get()
    return try ColorAdjustmentKernelSpace.apply(to: image, kernelName: "brightroomSpatialTone") { input in
      guard let logLuminance = kernels.luminance.apply(extent: input.extent, arguments: [input, Float(control)]) else {
        throw FeatureEvaluationError.imageCreationFailed("Spatial tone luminance")
      }
      // Large neighborhoods are evaluated on a bounded analysis image. The
      // output still uses every original RGB pixel, with no image readback.
      let factor = min(1, 512 / max(input.extent.width, input.extent.height))
      let extent = input.extent.applying(.init(scaleX: factor, y: factor))
      let guide = logLuminance.clampedToExtent().applyingFilter("CILanczosScaleTransform",
        parameters: [kCIInputScaleKey: factor, "inputAspectRatio": 1]).cropped(to: extent)
      let radiusScale = max(extent.width, extent.height) / 1024
      let blurred = [4.0, 16, 64, 256].map { radius in
        guide.clampedToExtent().applyingFilter("CIGaussianBlur",
          parameters: [kCIInputRadiusKey: radius * radiusScale]).cropped(to: extent)
      }
      let mean = guide.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: extent)])
      guard let deviations = kernels.deviations.apply(extent: extent,
        roiCallback: { index, rect in index == 2 ? mean.extent : rect },
        arguments: [guide, blurred[0], mean]) else {
        throw FeatureEvaluationError.imageCreationFailed("Spatial tone deviations")
      }
      // A second pass measures squared deviations directly, avoiding the
      // cancellation of E[x²] - E[x]² in half-float rendering of flat fields.
      let statistics = deviations.applyingFilter("CIAreaAverage",
        parameters: [kCIInputExtentKey: CIVector(cgRect: extent)])
      let table = calibration.table
      let colorGains: CIImage
      if control == 0 {
        // The two image-wide statistics select one color response for this render.
        // A full-resolution pixel then interpolates only its luminance and measured loss.
        guard let gains = kernels.highlightColorGains.apply(extent: CGRect(x: 0, y: 0, width: 33, height: 33),
          roiCallback: { _, _ in statistics.extent }, arguments: [statistics]) else {
          throw FeatureEvaluationError.imageCreationFailed("Highlights color response")
        }
        colorGains = gains
      } else if control == 2 {
        // Four luminance knots share the same scene weights across the whole image.
        guard let gains = kernels.shadowColorGains.apply(extent: CGRect(x: 0, y: 0, width: 4, height: 4),
          roiCallback: { _, _ in statistics.extent }, arguments: [statistics]) else {
          throw FeatureEvaluationError.imageCreationFailed("Shadows color response")
        }
        colorGains = gains
      } else {
        colorGains = statistics
      }
      // The GPU shapes the −25, −50 and −100 intervals from the first three
      // components. The fourth pins Highlights to its measured −10 step.
      let scales = calibration.model.amountScales[control]
      let negativeInterval = CIVector(x: highlights ? scales[2] : 0, y: scales[3], z: scales[4], w: scales[1])
      func spatialResponse(to source: CIImage, guideScale: CGFloat, magnitude: Double,
        colors: CIImage? = nil, correction: CIImage? = nil, sceneTone: CIImage? = nil,
        sampleScale: CGFloat = 0) throws -> CIImage {
        let colors = colors ?? statistics
        let correction = correction ?? statistics
        let gainTable = control == 0 ? calibration.highlightStrength : statistics
        let tone = sceneTone ?? statistics
        guard let output = kernels.response.apply(extent: source.extent,
          roiCallback: { index, rect in
            switch index {
            case 0: rect
            // A tile needs consistent Gaussian boundaries on the analysis grid.
            case 1...4: extent
            case 5: statistics.extent
            case 6: table.extent
            case 7: gainTable.extent
            case 8: mean.extent
            case 9: colorGains.extent
            case 10: colors.extent
            case 11: correction.extent
            default: tone.extent
            }
          }, arguments: [source] + blurred + [statistics, table, gainTable, mean, colorGains, colors, correction, tone, Float(guideScale),
            Float(control), Float(calibration.model.strength(magnitude, control: control)), Float(magnitude),
            negativeInterval,
            Float(calibration.model.centers.count), Float(0.5 / pow(calibration.model.width, 2)), Float(sampleScale)]) else {
          throw FeatureEvaluationError.imageCreationFailed("brightroomSpatialTone")
        }
        return output
      }
      guard amount < 0 else { return try spatialResponse(to: input, guideScale: factor, magnitude: amount) }

      // Compare the −50 luminance loss at nearby source colors once on a
      // bounded grid. Every slider amount then uses the same spatial correction
      // before its calibrated strength curve and gamut limits.
      let longEdge = max(input.extent.width, input.extent.height)
      let sampleScale = min(1, 256 / longEdge)
      let transform = CGAffineTransform(scaleX: sampleScale, y: sampleScale)
      let guideExtent = input.extent.applying(transform).integral
      let smallInput = input.clampedToExtent().samplingNearest().transformed(by: transform).cropped(to: guideExtent)
      let smallOutput = try spatialResponse(to: smallInput, guideScale: factor / sampleScale, magnitude: 50)
      guard let colors = kernels.neighborColor.apply(extent: guideExtent, arguments: [smallInput]),
        let losses = kernels.neighborLoss.apply(extent: guideExtent, arguments: [smallInput, smallOutput]),
        let correction = kernels.neighborResponse.apply(extent: guideExtent,
          roiCallback: { _, _ in guideExtent },
          arguments: [colors, losses, Float(longEdge * sampleScale / 1024), CIVector(cgRect: guideExtent), Float(control)]) else {
        throw FeatureEvaluationError.imageCreationFailed("Spatial tone color neighborhoods")
      }
      // Each luminance bin describes the predicted −50 loss of comparable tones
      // throughout the image. Rows sample independent strips of the bounded guide.
      let rowsExtent = CGRect(x: 0, y: 0, width: 128, height: 32)
      guard let rows = kernels.sceneToneRows.apply(extent: rowsExtent,
        roiCallback: { _, _ in guideExtent },
        arguments: [losses, CIVector(cgRect: guideExtent)]) else {
        throw FeatureEvaluationError.imageCreationFailed("Spatial scene tone response")
      }
      let histogram = rows.applyingFilter("CIColumnAverage",
        parameters: [kCIInputExtentKey: CIVector(cgRect: rowsExtent)])
      let sceneTone: CIImage
      if highlights {
        // Append upper-tone spread and midtone protection to the existing loss bins.
        let extent = CGRect(x: 0, y: 0, width: rowsExtent.width + 1, height: 1)
        guard let metered = kernels.highlightSceneQuantiles.apply(extent: extent,
          roiCallback: { _, _ in histogram.extent }, arguments: [histogram]) else {
          throw FeatureEvaluationError.imageCreationFailed("Highlights scene quantiles")
        }
        sceneTone = metered
      } else {
        sceneTone = histogram
      }
      return try spatialResponse(to: input, guideScale: factor, magnitude: abs(amount),
        colors: colors, correction: correction, sceneTone: sceneTone, sampleScale: sampleScale)
    }
  }

  private struct Kernels {
    let luminance: CIColorKernel
    let deviations: CIKernel
    let highlightColorGains: CIKernel
    let shadowColorGains: CIKernel
    let sceneToneRows: CIKernel
    let highlightSceneQuantiles: CIKernel
    let response: CIKernel
    let neighborColor: CIColorKernel
    let neighborLoss: CIColorKernel
    let neighborResponse: CIKernel
  }

  private static let kernels: Result<Kernels, FeatureEvaluationError> = {
    do {
      let data = try ColorAdjustmentMetalLibrary.data()
      return .success(Kernels(
        luminance: try CIColorKernel(functionName: "brightroomToneLuminance", fromMetalLibraryData: data),
        deviations: try CIKernel(functionName: "brightroomToneDeviations", fromMetalLibraryData: data),
        highlightColorGains: try CIKernel(functionName: "brightroomHighlightColorGains", fromMetalLibraryData: data),
        shadowColorGains: try CIKernel(functionName: "brightroomShadowColorGains", fromMetalLibraryData: data),
        sceneToneRows: try CIKernel(functionName: "brightroomSceneToneRows", fromMetalLibraryData: data),
        highlightSceneQuantiles: try CIKernel(functionName: "brightroomHighlightSceneQuantiles", fromMetalLibraryData: data),
        response: try CIKernel(functionName: "brightroomSpatialTone", fromMetalLibraryData: data),
        neighborColor: try CIColorKernel(functionName: "brightroomToneNeighborColor", fromMetalLibraryData: data),
        neighborLoss: try CIColorKernel(functionName: "brightroomToneNeighborLoss", fromMetalLibraryData: data),
        neighborResponse: try CIKernel(functionName: "brightroomToneNeighborResponse", fromMetalLibraryData: data)))
    } catch {
      return .failure(.kernelUnavailable(name: "brightroomSpatialTone", reason: String(describing: error)))
    }
  }()

  /// Nine normalized scene measurements and four signed responses per basis.
  /// The amount axis is measured independently on a neutral grayscale ramp.
  private struct Model: Decodable {
    let mean: [Double]
    let scale: [Double]
    let centers: [[Double]]
    let weights: [[Double]]
    let width: Double
    let amountKnots: [Double]
    let amountScales: [[Double]]

    func strength(_ amount: Double, control: Int) -> Double {
      let upper = amountKnots.firstIndex { $0 > amount } ?? (amountKnots.count - 1)
      let lower = upper - 1
      let fraction = (amount - amountKnots[lower]) / (amountKnots[upper] - amountKnots[lower])
      return amountScales[control][lower] * (1 - fraction) + amountScales[control][upper] * fraction
    }
  }

  private struct Calibration {
    let model: Model
    let table: CIImage
    let highlightStrength: CIImage
  }

  private static let calibration: Result<Calibration, FeatureEvaluationError> = {
    do {
      guard let url = Bundle.module.url(forResource: "HighlightShadowCalibration", withExtension: "json") else {
        throw FeatureEvaluationError.imageCreationFailed("Missing spatial tone calibration")
      }
      let model = try JSONDecoder().decode(Model.self, from: Data(contentsOf: url))
      let allValues = model.mean + model.scale + model.centers.flatMap { $0 }
        + model.weights.flatMap { $0 } + model.amountScales.flatMap { $0 } + [model.width]
      guard model.mean.count == 9, model.scale.count == 9,
        model.scale.allSatisfy({ $0 > 0 }), model.centers.count == 192,
        model.centers.allSatisfy({ $0.count == 9 }), model.weights.count == 192,
        model.weights.allSatisfy({ $0.count == 4 }), model.width > 0,
        model.amountKnots == [0, 10, 25, 50, 100], model.amountScales.count == 4,
        model.amountScales.allSatisfy({ $0.count == 5 }), allValues.allSatisfy({ $0.isFinite }) else {
        throw FeatureEvaluationError.imageCreationFailed("Invalid spatial tone calibration")
      }
      // RGB stores coefficients, with opaque alpha. No coefficient is treated
      // as coverage by Core Image. The first two rows hold normalization data.
      let height = model.centers.count + 2
      var pixels = [Float](repeating: 0, count: 5 * height * 4)
      func write(_ values: [Double], row: Int, firstColumn: Int = 0) {
        for (index, value) in values.enumerated() {
          pixels[((height - row - 1) * 5 + firstColumn + index / 3) * 4 + index % 3] = Float(value)
        }
      }
      for index in stride(from: 3, to: pixels.count, by: 4) { pixels[index] = 1 }
      write(model.mean, row: 0)
      write(model.scale.map { 1 / $0 }, row: 1)
      for index in model.centers.indices {
        write(model.centers[index], row: index + 2)
        write(model.weights[index], row: index + 2, firstColumn: 3)
      }
      let table = CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) },
        bytesPerRow: 5 * 16, size: CGSize(width: 5, height: height), format: .RGBAf, colorSpace: nil)
      // The two axes use the mean and the deviation of the smoothed log-luminance
      // guide already measured by this recipe. Each texel is a linear-response gain.
      guard let gainURL = Bundle.module.url(forResource: "HighlightStrength", withExtension: "bin") else {
        throw FeatureEvaluationError.imageCreationFailed("Missing Highlights strength table")
      }
      let gains = try Data(contentsOf: gainURL)
      guard gains.count == 65 * 33 * MemoryLayout<Float>.stride else {
        throw FeatureEvaluationError.imageCreationFailed("Invalid Highlights strength table")
      }
      let gainTable = CIImage(bitmapData: gains, bytesPerRow: 65 * MemoryLayout<Float>.stride,
        size: CGSize(width: 65, height: 33), format: .Rf, colorSpace: nil)
      return .success(Calibration(model: model, table: table, highlightStrength: gainTable))
    } catch let error as FeatureEvaluationError {
      return .failure(error)
    } catch {
      return .failure(.imageCreationFailed("Spatial tone calibration: \(error)"))
    }
  }()
}
