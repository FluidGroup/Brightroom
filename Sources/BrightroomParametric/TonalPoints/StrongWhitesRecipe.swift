// Copyright (c) 2026 Hiroshi Kimura (Muukii)

import BrightroomColorAdjustmentKernels
import CoreImage
import Foundation

/// Selects a measured RGB response from the luminance distribution of a developed image.
///
/// Fine contrast determines how much a local average contributes to the luminance histogram.
/// The quantiles estimate strength across the calibrated range. Similar histograms
/// also contribute their measured strength. When flat regions span different luminance
/// levels, the estimate gives less weight to how much area each level occupies.
/// A colored ROMM channel approaching white limits the lift according to its coverage.
/// At the +75 endpoint, a luminance distribution with a long bright tail
/// receives less lift, and one with a long dark tail receives more. When that
/// asymmetry is concentrated toward the ends of the histogram, the remaining
/// white headroom scales its contribution. The +50 response bounds the lift from below.
nonisolated enum StrongWhitesRecipe {

  static func apply(to input: CIImage, amount: Double) throws -> CIImage {
    let kernels = try kernels.get()
    let calibration = try calibration.get()
    let extent = input.extent
    let scale = min(1, 256 / max(extent.width, extent.height))
    let width = max(1, Int(ceil(extent.width * scale)))
    let height = max(1, Int(ceil(extent.height * scale)))
    let guideExtent = CGRect(x: 0, y: 0, width: width, height: height)
    let strideX = extent.width / CGFloat(width)
    let strideY = extent.height / CGFloat(height)

    guard let luminance = kernels.luminance.apply(extent: extent, arguments: [input]) else {
      throw FeatureEvaluationError.imageCreationFailed("Whites encoded luminance")
    }
    let sigma = max(extent.width, extent.height) * calibration.model.blurScale
    let blurred = luminance.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
    guard let guide = kernels.sample.apply(extent: guideExtent,
      roiCallback: { _, rect in
        rect.applying(.init(scaleX: strideX, y: strideY))
          .offsetBy(dx: extent.minX, dy: extent.minY)
          .insetBy(dx: -1, dy: -1).intersection(extent)
      }, arguments: [luminance, blurred, input, CIVector(x: extent.minX, y: extent.minY), CIVector(x: strideX, y: strideY)])
    else { throw FeatureEvaluationError.imageCreationFailed("Whites distribution samples") }

    let guideArea = [kCIInputExtentKey: CIVector(cgRect: guideExtent)]
    let mean = guide.applyingFilter("CIAreaAverage", parameters: guideArea)
    guard let contrast = kernels.contrast.apply(extent: guideExtent,
      roiCallback: { index, rect in index == 0 ? rect : mean.extent }, arguments: [guide, mean])
    else { throw FeatureEvaluationError.imageCreationFailed("Whites luminance contrast") }
    let energy = contrast.applyingFilter("CIAreaAverage", parameters: guideArea)

    // Each row counts an 8×8 tile. The first 43 columns hold its 128 luminance
    // bins. The last column measures the luminance variation in flat regions.
    let histogramExtent = CGRect(x: 0, y: 0, width: 44, height: ((width + 7) / 8) * ((height + 7) / 8))
    guard let histogram = kernels.histogram.apply(extent: histogramExtent,
      roiCallback: { index, _ in index == 0 ? guideExtent : energy.extent },
      arguments: [guide, energy, CIVector(x: guideExtent.width, y: guideExtent.height)])
    else { throw FeatureEvaluationError.imageCreationFailed("Whites luminance histogram") }
    let bins = histogram.applyingFilter("CIColumnAverage",
      parameters: [kCIInputExtentKey: CIVector(cgRect: histogramExtent)])

    let model = calibration.model
    let sceneExtent = calibration.distributions.extent
    let positions = calibration.positions
    let coefficients = CIVector(x: model.uniformSlope, y: model.meanWeight, z: model.inverseWidth)
    let curve = CIVector(x: model.upperCurve[0], y: model.upperCurve[1],
      z: model.upperCurve[2], w: model.upperCurve[3])
    let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
    let atlas = calibration.atlas
    func displacement(at strength: Double) throws -> CIImage {
      guard let displacement = kernels.displacement.apply(extent: unit,
        roiCallback: { index, _ in
          switch index {
          case 0: bins.extent
          case 1: sceneExtent
          case 2: positions.extent
          default: mean.extent
          }
        }, arguments: [bins, calibration.distributions, positions, mean, coefficients, model.law(at: strength),
          curve, model.histogramExponent, Float(sceneExtent.height), Float(model.displacements.count)])
      else { throw FeatureEvaluationError.imageCreationFailed("Whites gray response") }
      return displacement
    }
    func response(_ displacement: CIImage) throws -> CIImage {
      guard let output = kernels.response.apply(extent: extent,
        roiCallback: { index, rect in
          switch index {
          case 0: rect
          case 1: atlas.extent
          default: unit
          }
        }, arguments: [input, atlas, displacement, calibration.atlasLayout])
      else { throw FeatureEvaluationError.imageCreationFailed("Strong Whites response") }
      return output.cropped(to: extent)
    }
    if amount > 50 && amount < 75 {
      // These two endpoints share a histogram. Fixed endpoint colors keep a
      // bright-ramp pixel from reversing as the slider crosses this interval.
      let start = try response(displacement(at: 50))
      let end = try response(displacement(at: 75))
      return start.applyingFilter("CIDissolveTransition",
        parameters: [kCIInputTargetImageKey: end, kCIInputTimeKey: (amount - 50) / 25]).cropped(to: extent)
    }
    let currentDisplacement = try displacement(at: amount)
    guard amount > 75 else { return try response(currentDisplacement) }

    let endpointDisplacement = amount == 100 ? currentDisplacement : try displacement(at: 100)
    let endpoint = try response(endpointDisplacement)
    guard let channels = kernels.peaks.apply(extent: extent, arguments: [input, endpoint]) else {
      throw FeatureEvaluationError.imageCreationFailed("Whites peak channels")
    }
    // The maximum across the full input includes bright details smaller than one analysis cell.
    let peaks = channels.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: extent)])
    guard let corrected = kernels.peakResponse.apply(extent: extent,
      roiCallback: { index, rect in
        switch index {
        case 0: rect
        case 1: atlas.extent
        case 4: peaks.extent
        default: unit
        }
      },
      arguments: [input, atlas, currentDisplacement, endpointDisplacement, peaks, calibration.atlasLayout, Float((amount - 75) / 25),
        CIVector(x: model.minimumPeak, y: model.peakShoulder)])
    else { throw FeatureEvaluationError.imageCreationFailed("Whites upper endpoint") }
    return corrected.cropped(to: extent)
  }

  private struct Kernels {
    let luminance: CIColorKernel
    let sample: CIKernel
    let contrast: CIKernel
    let histogram: CIKernel
    let displacement: CIKernel
    let response: CIKernel
    let peaks: CIColorKernel
    let peakResponse: CIKernel
  }

  private static let kernels: Result<Kernels, FeatureEvaluationError> = {
    do {
      let data = try ColorAdjustmentMetalLibrary.data()
      func kernel(_ name: String) throws -> CIKernel { try CIKernel(functionName: name, fromMetalLibraryData: data) }
      return .success(try Kernels(
        luminance: CIColorKernel(functionName: "brightroomWhitesEncodedLuminance", fromMetalLibraryData: data),
        sample: kernel("brightroomWhitesDistributionSample"), contrast: kernel("brightroomWhitesContrast"),
        histogram: kernel("brightroomWhitesHistogram"), displacement: kernel("brightroomWhitesDisplacement"),
        response: kernel("brightroomStrongWhites"),
        peaks: CIColorKernel(functionName: "brightroomWhitesPeaks", fromMetalLibraryData: data),
        peakResponse: kernel("brightroomWhitesPeakResponse")))
    } catch {
      return .failure(.kernelUnavailable(name: "Strong Whites", reason: String(describing: error)))
    }
  }()

  /// The measured scenes map luminance distributions to a gray displacement. Each
  /// atlas layer records the changes of the minimum and maximum linear ROMM channels.
  /// At the start of a white plateau the stored changes can extend past white.
  /// The response kernel clips the endpoints after interpolating color and strength.
  private struct Model: Decodable {
    let distributions: [[Float]]
    let dimension: Int
    let rowWidth: Int
    let displacements: [Float]
    let uniformSlope, meanWeight, inverseWidth, histogramExponent: CGFloat
    /// Coefficients of the measured +100 displacement q(a + bq) / (1 + cq + dq²), where q is the +75 displacement.
    let upperCurve: [CGFloat]
    let blurScale, minimumPeak, peakShoulder: CGFloat
    let amountLaw: [[CGFloat]]

    /// Log gain and exponent for the requested lower strength, or for the +50 floor at upper strengths.
    /// The last two components give the interpolation toward +100 and select the measured +75 endpoint.
    /// Strengths between +50 and +75 blend the two endpoint images in `apply(to:amount:)`.
    func law(at amount: Double) -> CIVector {
      if amount >= 75 {
        let at50 = amountLaw[1]
        return CIVector(x: at50[0], y: at50[1], z: log(CGFloat(amount) / 75) / log(100.0 / 75.0), w: 1)
      }
      let index = min(max(Int(amount / 25) - 1, 0), 1)
      let lower = CGFloat(25 * (index + 1))
      let fraction = log(CGFloat(amount) / lower) / log((lower + 25) / lower)
      let a = amountLaw[index], b = amountLaw[index + 1]
      return CIVector(x: a[0] + (b[0] - a[0]) * fraction, y: a[1] + (b[1] - a[1]) * fraction, z: 0, w: 0)
    }
  }

  private struct Calibration {
    let model: Model
    let distributions: CIImage
    let positions: CIImage
    let atlas: CIImage
    /// Number of levels per channel, texels per row, and rows per response layer.
    let atlasLayout: CIVector
  }

  private static let calibration: Result<Calibration, FeatureEvaluationError> = {
    do {
      guard let url = Bundle.module.url(forResource: "StrongWhitesCalibration", withExtension: "lzfse") else {
        throw FeatureEvaluationError.imageCreationFailed("Missing strong Whites calibration")
      }
      let packed = try Data(contentsOf: url) as NSData
      let data = try packed.decompressed(using: .lzfse) as Data
      guard data.count >= 12, data.prefix(8) == Data("BRWH0008".utf8) else {
        throw FeatureEvaluationError.imageCreationFailed("Invalid strong Whites header")
      }
      let length = data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian) }
      let start = 12 + length
      guard start <= data.count else { throw FeatureEvaluationError.imageCreationFailed("Invalid strong Whites header size") }
      let model = try JSONDecoder().decode(Model.self, from: data.subdata(in: 12..<start))
      guard model.dimension == 63, model.rowWidth == 256, (2...128).contains(model.displacements.count),
        model.displacements.first == 0, model.displacements.allSatisfy(\.isFinite),
        zip(model.displacements, model.displacements.dropFirst()).allSatisfy({ $0 < $1 }),
        model.uniformSlope.isFinite, model.meanWeight >= 0, model.inverseWidth > 0,
        model.upperCurve.count == 4, model.upperCurve.allSatisfy({ $0.isFinite && $0 > 0 }),
        model.histogramExponent.isFinite, model.histogramExponent > 0,
        model.blurScale.isFinite, model.blurScale > 0, model.blurScale <= 1,
        model.minimumPeak > 0, model.minimumPeak < 1, model.peakShoulder > 0, model.peakShoulder < 1,
        model.amountLaw.count == 3, model.amountLaw.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }),
        !model.distributions.isEmpty,
        model.distributions.allSatisfy({ $0.count == 33 && $0.allSatisfy(\.isFinite) })
      else { throw FeatureEvaluationError.imageCreationFailed("Invalid strong Whites measurements") }
      let levels = model.dimension
      let orderedColors = levels * (levels + 1) * (levels + 2) / 6
      let width = model.rowWidth
      let rowsPerLayer = (orderedColors + width - 1) / width
      let height = rowsPerLayer * model.displacements.count
      guard data.count - start == width * height * 4 else {
        throw FeatureEvaluationError.imageCreationFailed("Invalid strong Whites atlas size")
      }
      let atlas = CIImage(bitmapData: data.subdata(in: start..<data.count), bytesPerRow: width * 4,
        size: CGSize(width: width, height: height), format: .RGh, colorSpace: nil)
      let layout = CIVector(x: CGFloat(levels), y: CGFloat(width), z: CGFloat(rowsPerLayer))
      var rows = [SIMD4<Float>]()
      for scene in model.distributions.reversed() {
        for i in stride(from: 0, to: scene.count, by: 3) {
          rows.append(.init(scene[i], scene[i + 1], scene[i + 2], 1))
        }
      }
      let columns = model.distributions[0].count / 3
      let distributionImage = CIImage(bitmapData: rows.withUnsafeBytes { Data($0) }, bytesPerRow: columns * 16,
        size: CGSize(width: columns, height: model.distributions.count), format: .RGBAf, colorSpace: nil)
      let positions = model.displacements.map { SIMD4<Float>($0, 0, 0, 1) }
      let positionImage = CIImage(bitmapData: positions.withUnsafeBytes { Data($0) }, bytesPerRow: positions.count * 16,
        size: CGSize(width: positions.count, height: 1), format: .RGBAf, colorSpace: nil)
      return .success(Calibration(model: model, distributions: distributionImage, positions: positionImage,
        atlas: atlas, atlasLayout: layout))
    } catch let error as FeatureEvaluationError {
      return .failure(error)
    } catch {
      return .failure(.imageCreationFailed("Strong Whites calibration: \(error)"))
    }
  }()
}
