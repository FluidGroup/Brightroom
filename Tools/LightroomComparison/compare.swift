// Compare two opaque, full-resolution SDR images after interpreting their ICC
// profiles. This scratch measurement tool does not implement an Adobe effect.
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import simd
import UniformTypeIdentifiers

func require(_ condition: Bool, _ message: String) {
  if !condition { fputs("Comparison inconclusive: \(message)\n", stderr); exit(2) }
}

/// A measured file, retaining the original profile and encoded-byte identity.
struct Input {
  let image: CIImage
  let width: Int
  let height: Int
  let evidence: [String: Any]

  init(_ path: String) throws {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let bitmap = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
      properties[kCGImagePropertyProfileName as String] != nil,
      let profile = bitmap.colorSpace,
      let recipe = CIImage(contentsOf: url, options: [.applyOrientationProperty: false])
    else { throw NSError(domain: "Missing image or embedded ICC profile: \(path)", code: 1) }
    require((properties[kCGImagePropertyOrientation as String] as? Int ?? 1) == 1,
      "orientation must be normalized before comparison")
    require(bitmap.bitsPerComponent == 16, "expected a 16-bit reference/candidate")
    image = recipe
    width = bitmap.width
    height = bitmap.height
    evidence = ["path": url.path, "width": width, "height": height,
      "bitsPerComponent": bitmap.bitsPerComponent,
      "profile": profile.name as String? ?? "unnamed embedded ICC",
      "sha256": SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()]
  }
}

/// Accumulates error without changing image geometry or fitting alignment.
struct ErrorSummary {
  var pixels = 0
  var absolute = [Double](repeating: 0, count: 3)
  var squared = [Double](repeating: 0, count: 3)
  var signed = [Double](repeating: 0, count: 3)
  var maximum = 0.0

  mutating func add(_ differences: [Double]) {
    pixels += 1
    for channel in 0..<3 {
      let delta = differences[channel]
      absolute[channel] += abs(delta)
      squared[channel] += delta * delta
      signed[channel] += delta
      maximum = max(maximum, abs(delta))
    }
  }

  var json: [String: Any] {
    guard pixels > 0 else { return ["pixels": 0] }
    return ["pixels": pixels, "channelMAE": absolute.map { $0 / Double(pixels) },
      "channelRMSE": squared.map { sqrt($0 / Double(pixels)) },
      "channelBias": signed.map { $0 / Double(pixels) }, "maxAbsolute": maximum]
  }
}

var arguments = Array(CommandLine.arguments.dropFirst())
let measuresResponseAxes = arguments.contains("--response-axes")
arguments.removeAll { $0 == "--response-axes" }
let colorSource: Input?
if arguments.count >= 2 && arguments[arguments.count - 2] == "--middle-channel-source" {
  colorSource = try Input(arguments.removeLast())
  arguments.removeLast()
} else {
  colorSource = nil
}
require([3, 5].contains(arguments.count),
  "usage: compare-postraw reference candidate output-directory [reference-baseline candidate-baseline] [--response-axes] [--middle-channel-source image]")
require(!measuresResponseAxes || arguments.count == 5, "response axes require paired baseline images")
let reference = try Input(arguments[0])
let candidate = try Input(arguments[1])
let referenceBaseline = arguments.count == 5 ? try Input(arguments[3]) : nil
let candidateBaseline = arguments.count == 5 ? try Input(arguments[4]) : nil
require(reference.width == candidate.width && reference.height == candidate.height,
  "dimensions differ; resizing/registration is not part of a color comparison")
if let colorSource {
  require(colorSource.width == reference.width && colorSource.height == reference.height,
    "middle-channel source dimensions differ")
}
for baseline in [referenceBaseline, candidateBaseline].compactMap({ $0 }) {
  require(baseline.width == reference.width && baseline.height == reference.height,
    "baseline dimensions differ")
}
let destination = URL(fileURLWithPath: arguments[2], isDirectory: true)
require(!FileManager.default.fileExists(atPath: destination.path), "output directory already exists")
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
// Float32 decoding avoids making the measurement's precision depend on the
// half-float working format of the production renderer being investigated.
let context = CIContext(options: [.workingColorSpace: space,
  .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false, .useSoftwareRenderer: true])
let width = reference.width
let height = reference.height
let heatScale = 10
let heatWidth = (width + heatScale - 1) / heatScale
let heatHeight = (height + heatScale - 1) / heatScale
var heat = [Float](repeating: 0, count: heatWidth * heatHeight)
var errors = [Float]()
errors.reserveCapacity(width * height)
var responseErrors = [Float]()
var middleChannelErrors = [Float]()
// Exclude ICC and 16-bit rounding around zero. Wide-gamut exports can
// legitimately contain much smaller linear-P3 components.
let negativeP3Threshold: Float = -0.001
var negativeMinimumErrors = [Float]()
var negativeRGBErrors = [Float]()
var negativeCandidatePixels = 0
var negativeMatchedPixels = 0
// Nearly neutral inputs do not give the middle channel a stable position.
let minimumChannelSpan = 0.02
if referenceBaseline != nil { responseErrors.reserveCapacity(width * height) }
var total = ErrorSummary()
var responseTotal = ErrorSummary()
let binNames = ["Y < 0.01", "0.01 <= Y < 0.18", "0.18 <= Y < 0.75", "Y >= 0.75"]
var bins = [ErrorSummary](repeating: ErrorSummary(), count: binNames.count)

/// Measures how the baseline error and the error introduced by an adjustment combine.
/// Their squared lengths and dot product reconstruct the adjusted image's squared RGB error.
struct PairedErrorEnergy {
  var baselineSquared = 0.0
  var responseSquared = 0.0
  var crossProduct = 0.0

  mutating func add(baseline: Double, response: Double) {
    baselineSquared += baseline * baseline
    responseSquared += response * response
    crossProduct += baseline * response
  }

  mutating func merge(_ other: Self) {
    baselineSquared += other.baselineSquared
    responseSquared += other.responseSquared
    crossProduct += other.crossProduct
  }

  func statistics(pixels: Int) -> [String: Any] {
    guard pixels > 0 else { return ["pixels": 0] }
    let components = Double(pixels) * 3
    var result: [String: Any] = [
      "pixels": pixels, "baselineMSE": baselineSquared / components,
      "responseMSE": responseSquared / components, "twiceMeanProduct": 2 * crossProduct / components,
    ]
    if baselineSquared > 0 && responseSquared > 0 {
      result["cosine"] = max(-1, min(1, crossProduct / (sqrt(baselineSquared) * sqrt(responseSquared))))
    }
    return result
  }
}

/// Signed changes within one luminance band of the Lightroom baseline.
/// For group omissions, each baseline is the same preset with the group removed.
struct LuminanceResponse {
  var pixels = 0
  var referenceSum = 0.0
  var candidateSum = 0.0
  var errorEnergy = PairedErrorEnergy()

  mutating func add(reference: Double, candidate: Double) {
    pixels += 1
    referenceSum += reference
    candidateSum += candidate
  }

  var json: [String: Any] {
    guard pixels > 0 else { return ["pixels": 0] }
    let reference = referenceSum / Double(pixels)
    let candidate = candidateSum / Double(pixels)
    return ["pixels": pixels, "referenceMeanChange": reference, "candidateMeanChange": candidate,
      "signedMeanError": candidate - reference, "errorEnergy": errorEnergy.statistics(pixels: pixels)]
  }
}

func luminance(_ rgba: [Float], at i: Int) -> Double {
  0.228974564 * Double(rgba[i]) + 0.691738522 * Double(rgba[i+1]) + 0.079286914 * Double(rgba[i+2])
}

/// Resolves the signed RGB response error along luminance and the two color
/// directions defined by the candidate's neutral pixel in linear Display P3.
struct ResponseAxes {
  private let luminance = SIMD3(0.228974564, 0.691738522, 0.079286914)
  private let gray = SIMD3<Double>(repeating: 1 / sqrt(3))
  private var brightness = [Float]()
  private var radial = [Float]()
  private var tangential = [Float]()

  mutating func add(error: SIMD3<Double>, neutral: SIMD3<Double>) {
    brightness.append(Float(abs(simd_dot(error, luminance))))
    guard neutral.max() - neutral.min() > minimumChannelSpan else { return }
    let along = simd_normalize(neutral - neutral.sum() / 3)
    let across = simd_cross(gray, along)
    // Subtract each direction's luminance so changing color alone keeps Y fixed.
    func magnitude(along direction: SIMD3<Double>) -> Float {
      let rgb = (direction - simd_dot(direction, luminance)) * simd_dot(error, direction)
      return Float(simd_abs(rgb).max())
    }
    radial.append(magnitude(along: along))
    tangential.append(magnitude(along: across))
  }

  mutating func statistics() -> [String: Any] {
    func summary(_ values: inout [Float]) -> [String: Any] {
      guard !values.isEmpty else { return ["pixels": 0] }
      values.sort()
      return ["pixels": values.count, "p95": values[Int(ceil(0.95 * Double(values.count))) - 1]]
    }
    return ["luminance": summary(&brightness), "chromaAlongSourceHue": summary(&radial),
      "chromaAcrossSourceHue": summary(&tangential), "minimumNeutralChannelSpan": minimumChannelSpan,
      "meaning": "Per-pixel maximum absolute linear RGB component in each direction. Color directions use pixels above the minimum neutral span."]
  }
}

var responseAxes = ResponseAxes()
let neutralBoundaries = [0.01, 0.05, 0.18, 0.50, 0.75, 0.90]
let neutralBandNames = ["Y < 0.01", "0.01 <= Y < 0.05", "0.05 <= Y < 0.18",
  "0.18 <= Y < 0.50", "0.50 <= Y < 0.75", "0.75 <= Y < 0.90", "Y >= 0.90"]
var luminanceResponses = [LuminanceResponse](repeating: LuminanceResponse(), count: neutralBandNames.count)
var refRange = [Float.infinity, -Float.infinity]
var candRange = [Float.infinity, -Float.infinity]

for y in stride(from: 0, to: height, by: 128) {
  let tileHeight = min(128, height - y)
  let count = width * tileHeight * 4
  var a = [Float](repeating: .nan, count: count)
  var b = [Float](repeating: .nan, count: count)
  let bounds = CGRect(x: 0, y: y, width: width, height: tileHeight)
  context.render(reference.image, toBitmap: &a, rowBytes: width * 16,
    bounds: bounds, format: .RGBAf, colorSpace: space)
  context.render(candidate.image, toBitmap: &b, rowBytes: width * 16,
    bounds: bounds, format: .RGBAf, colorSpace: space)
  var original = [Float]()
  if let colorSource {
    original = [Float](repeating: .nan, count: count)
    context.render(colorSource.image, toBitmap: &original, rowBytes: width * 16,
      bounds: bounds, format: .RGBAf, colorSpace: space)
  }
  var a0 = [Float]()
  var b0 = [Float]()
  if let referenceBaseline, let candidateBaseline {
    a0 = [Float](repeating: .nan, count: count)
    b0 = [Float](repeating: .nan, count: count)
    context.render(referenceBaseline.image, toBitmap: &a0, rowBytes: width * 16,
      bounds: bounds, format: .RGBAf, colorSpace: space)
    context.render(candidateBaseline.image, toBitmap: &b0, rowBytes: width * 16,
      bounds: bounds, format: .RGBAf, colorSpace: space)
  }
  for pixel in 0..<(width * tileHeight) {
    let i = pixel * 4
    require((0..<4).allSatisfy { a[i+$0].isFinite && b[i+$0].isFinite }, "non-finite/unrendered pixels")
    require(abs(a[i+3] - 1) < 0.000001 && abs(b[i+3] - 1) < 0.000001,
      "non-opaque input; alpha requires a separate comparison contract")
    let delta = (0..<3).map { Double(b[i+$0]) - Double(a[i+$0]) }
    let maximum = Float(delta.map { abs($0) }.max()!)
    let referenceY = luminance(a, at: i)
    total.add(delta)
    errors.append(maximum)
    let referenceMinimum = min(a[i], min(a[i + 1], a[i + 2]))
    let candidateMinimum = min(b[i], min(b[i + 1], b[i + 2]))
    if candidateMinimum < negativeP3Threshold { negativeCandidatePixels += 1 }
    if referenceMinimum < negativeP3Threshold {
      negativeMinimumErrors.append(abs(candidateMinimum - referenceMinimum))
      negativeRGBErrors.append(maximum)
      if candidateMinimum < negativeP3Threshold { negativeMatchedPixels += 1 }
    }
    if !original.isEmpty {
      require((0..<4).allSatisfy { original[i+$0].isFinite } && abs(original[i+3] - 1) < 0.000001,
        "non-finite or non-opaque middle-channel source")
      var low = 0, high = 0
      for channel in 1..<3 {
        if original[i+channel] < original[i+low] { low = channel }
        if original[i+channel] > original[i+high] { high = channel }
      }
      let span = Double(original[i+high]) - Double(original[i+low])
      if span > minimumChannelSpan {
        let middle = 3 - low - high
        let fraction = (Double(original[i+middle]) - Double(original[i+low])) / span
        let expected = delta[low] + fraction * (delta[high] - delta[low])
        middleChannelErrors.append(Float(abs(delta[middle] - expected)))
      }
    }
    if !a0.isEmpty {
      require((0..<4).allSatisfy { a0[i+$0].isFinite && b0[i+$0].isFinite },
        "non-finite/unrendered baseline pixels")
      require(abs(a0[i+3] - 1) < 0.000001 && abs(b0[i+3] - 1) < 0.000001,
        "non-opaque baseline")
      let response = (0..<3).map { channel in
        (Double(b[i+channel]) - Double(b0[i+channel]))
          - (Double(a[i+channel]) - Double(a0[i+channel]))
      }
      responseTotal.add(response)
      responseErrors.append(Float(response.map { abs($0) }.max()!))
      if measuresResponseAxes {
        responseAxes.add(error: SIMD3(response[0], response[1], response[2]),
          neutral: SIMD3(Double(b0[i]), Double(b0[i+1]), Double(b0[i+2])))
      }
      let neutralY = luminance(a0, at: i)
      let band = neutralBoundaries.firstIndex { neutralY < $0 } ?? neutralBoundaries.count
      luminanceResponses[band].add(reference: referenceY - neutralY,
        candidate: luminance(b, at: i) - luminance(b0, at: i))
      for channel in 0..<3 {
        let baseline = Double(b0[i+channel]) - Double(a0[i+channel])
        luminanceResponses[band].errorEnergy.add(baseline: baseline, response: response[channel])
      }
    }
    let bin = referenceY < 0.01 ? 0 : referenceY < 0.18 ? 1 : referenceY < 0.75 ? 2 : 3
    bins[bin].add(delta)
    for channel in 0..<3 {
      refRange[0] = min(refRange[0], a[i+channel]); refRange[1] = max(refRange[1], a[i+channel])
      candRange[0] = min(candRange[0], b[i+channel]); candRange[1] = max(candRange[1], b[i+channel])
    }
    let x = pixel % width
    // Bounds use a bottom-left origin, but render(toBitmap:) writes each tile
    // top-to-bottom. Keep rows in the difference preview in source order.
    let topY = height - y - tileHeight + pixel / width
    let heatIndex = (topY / heatScale) * heatWidth + x / heatScale
    heat[heatIndex] = max(heat[heatIndex], maximum)
  }
}
errors.sort()
func percentile(_ probability: Double) -> Float {
  errors[max(0, Int(ceil(Double(errors.count) * probability)) - 1)]
}
let amplification: Float = 64
let heatBytes = Data(heat.map { UInt8(min(255, max(0, ($0 * amplification * 255).rounded()))) })
let provider = CGDataProvider(data: heatBytes as CFData)!
let heatImage = CGImage(width: heatWidth, height: heatHeight, bitsPerComponent: 8,
  bitsPerPixel: 8, bytesPerRow: heatWidth, space: CGColorSpaceCreateDeviceGray(),
  bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil,
  shouldInterpolate: false, intent: .defaultIntent)!
let heatURL = destination.appendingPathComponent("difference-x64.png")
let writer = CGImageDestinationCreateWithURL(heatURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(writer, heatImage, nil)
require(CGImageDestinationFinalize(writer), "could not write difference image")
var report: [String: Any] = [
  "status": "measured; no compatibility threshold assigned",
  "reference": reference.evidence, "candidate": candidate.evidence,
  "comparison": "extended-linear Display-P3 D65, Float32; candidate minus reference",
  "units": "linear RGB, 1.0 = diffuse output white; not perceptual Delta E or 8-bit code values",
  "renderer": "Core Image software renderer, RGBAf working format",
  "os": ProcessInfo.processInfo.operatingSystemVersionString,
  "allPixels": total.json,
  "pixelMaxChannelError": ["p50": percentile(0.5), "p95": percentile(0.95), "p99": percentile(0.99)],
  "referenceChannelRange": refRange, "candidateChannelRange": candRange,
  "luminanceBands": Dictionary(uniqueKeysWithValues: zip(binNames, bins.map { $0.json })),
  "differencePreview": ["path": heatURL.lastPathComponent,
    "meaning": "maximum absolute linear RGB channel error per 10 x 10 source block, multiplied by 64; white saturates at 1/64"]
]
if measuresResponseAxes { report["adjustmentResponseAxes"] = responseAxes.statistics() }
var belowBlack: [String: Any] = [
  "threshold": negativeP3Threshold, "referencePixels": negativeMinimumErrors.count,
  "candidatePixels": negativeCandidatePixels, "matchingPixels": negativeMatchedPixels,
  "meaning": "pixels with a linear Display-P3 component below the threshold",
]
if !negativeMinimumErrors.isEmpty {
  negativeMinimumErrors.sort()
  negativeRGBErrors.sort()
  let index = Int(ceil(0.95 * Double(negativeMinimumErrors.count))) - 1
  belowBlack["minimumChannelErrorP95"] = negativeMinimumErrors[index]
  belowBlack["pixelMaxChannelErrorP95"] = negativeRGBErrors[index]
}
report["belowDisplayP3Black"] = belowBlack
if let referenceBaseline, let candidateBaseline {
  responseErrors.sort()
  func responsePercentile(_ probability: Double) -> Float {
    responseErrors[max(0, Int(ceil(Double(responseErrors.count) * probability)) - 1)]
  }
  var energy = PairedErrorEnergy()
  for band in luminanceResponses { energy.merge(band.errorEnergy) }
  report["adjustmentResponseError"] = [
    "meaning": "(candidate - candidate baseline) - (reference - reference baseline); diagnostic, not a replacement for absolute error",
    "referenceBaseline": referenceBaseline.evidence,
    "candidateBaseline": candidateBaseline.evidence,
    "allPixels": responseTotal.json,
    "errorEnergy": energy.statistics(pixels: responseTotal.pixels),
    "byNeutralLuminance": Dictionary(uniqueKeysWithValues: zip(neutralBandNames, luminanceResponses.map(\.json))),
    "pixelMaxChannelError": ["p50": responsePercentile(0.5),
      "p95": responsePercentile(0.95), "p99": responsePercentile(0.99)],
  ]
}
if let colorSource {
  var result: [String: Any] = [
    "source": colorSource.evidence, "minimumSourceChannelSpan": minimumChannelSpan,
    "pixels": middleChannelErrors.count,
    "meaning": "absolute difference in middle-channel response at the source fraction between the outer channels in linear Display P3",
  ]
  if !middleChannelErrors.isEmpty {
    middleChannelErrors.sort()
    result["p95"] = middleChannelErrors[Int(ceil(0.95 * Double(middleChannelErrors.count))) - 1]
  }
  report["middleChannelError"] = result
}
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
try data.write(to: destination.appendingPathComponent("comparison.json"), options: .atomic)
FileHandle.standardOutput.write(data)
print()
