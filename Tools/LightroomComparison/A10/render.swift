// Host-side XMP mapping for the measured A10 experiment; not a library codec.
import BrightroomParametric
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import Metal

precondition(CommandLine.arguments.count == 5 || CommandLine.arguments.count == 6,
  "usage: render input-image settings.json output-directory point|legacy|partial|legacy-partial|calibrated|calibrated-light|tonal|adaptive|adaptive-no-grain|neutral [light-tables.bin]")
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let settingsURL = URL(fileURLWithPath: CommandLine.arguments[2])
let output = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
let mode = CommandLine.arguments[4]
precondition(["point", "legacy", "partial", "legacy-partial", "calibrated", "calibrated-light", "tonal", "adaptive", "adaptive-no-grain", "neutral"].contains(mode))
let partial = ["partial", "legacy-partial", "calibrated", "calibrated-light", "tonal", "adaptive", "adaptive-no-grain"].contains(mode)
let measuredLight = mode == "calibrated-light"
let includeGrain = mode == "adaptive"
let adaptive = includeGrain || mode == "adaptive-no-grain"
let tonal = mode == "tonal" || adaptive
let measuredMixer = mode == "calibrated" || measuredLight || tonal
precondition(!FileManager.default.fileExists(atPath: output.path), "Do not overwrite evidence")
let packet = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as! [String: Any]
func sha256(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
let outputProfile: Data?
if let path = packet["outputICC"] as? String {
  outputProfile = try Data(contentsOf: URL(fileURLWithPath: path))
} else if let path = packet["outputICCReference"] as? String {
  // Older registrations retain the tagged Lightroom TIFF without a separate ICC file.
  let bytes = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
  guard sha256(bytes) == packet["referenceSHA256"] as? String,
    let source = CGImageSourceCreateWithData(bytes as CFData, nil),
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
    properties[kCGImagePropertyProfileName] != nil,
    let bitmap = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
    let embedded = bitmap.colorSpace?.copyICCData()
  else { fatalError("Expected a registered Lightroom image with an embedded ICC profile: \(path)") }
  outputProfile = embedded as Data
} else {
  outputProfile = nil
}
let outputSpace = outputProfile.map { CGColorSpace(iccData: $0 as CFData)! } ?? CGColorSpace(name: CGColorSpace.rommrgb)!
let points = packet["curves"] as! [String: [[Double]]]
let settings = packet["settings"] as! [String: String]
func number(_ key: String, _ fallback: Double = 0) -> Double {
  guard let text = settings[key] else { return fallback }
  guard let value = Double(text), value.isFinite else { fatalError("Invalid parameter: \(key)") }
  return value
}
let legacy = mode == "legacy" || mode == "legacy-partial"
func coordinate(_ value: Double) -> Double {
  let encoded = value / 255
  guard legacy else { return encoded }
  // Retain the previous adapter exactly for a before/after comparison.
  let linear = encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
  let shift = -0.000157849851665374
  return linear < 0.0041318374739483946 ? linear * 363.034608563 / 14
    : (log2((linear + shift) / (0.18 + shift)) + 7) / 14
}
func curve(_ key: String) -> ToneCurve {
  guard let result = ToneCurve(validating: (points[key] ?? [[0, 0], [255, 255]]).map {
    .init(input: coordinate($0[0]), output: coordinate($0[1]))
  }) else { fatalError("Cannot represent \(key) without changing its points") }
  return result
}
var effects = [AnyImageEffect]()
if partial {
  effects.append(AnyImageEffect(ExposureFeature(ev: number("Exposure2012"))))
  if adaptive {
    effects.append(AnyImageEffect(HighlightsShadowsFeature(
      highlights: number("Highlights2012"), shadows: number("Shadows2012"))))
  } else {
    effects += [AnyImageEffect(HighlightsFeature(value: -number("Highlights2012") / 100)),
      AnyImageEffect(ShadowsFeature(value: number("Shadows2012") / 100))]
  }
  if measuredLight {
    precondition(CommandLine.arguments.count == 6, "Measured Light needs compiled tables")
    effects.append(AnyImageEffect(try MeasuredLightFeature(tableURL: URL(fileURLWithPath: CommandLine.arguments[5]))))
  } else {
    if tonal {
      effects += [AnyImageEffect(WhitesFeature(amount: number("Whites2012"))),
        AnyImageEffect(BlacksFeature(amount: number("Blacks2012")))]
    }
    effects.append(AnyImageEffect(adaptive ? SaturationFeature(lightroomAmount: number("Saturation"))
      : SaturationFeature(value: number("Saturation") / 100)))
  }
}
if mode != "neutral" {
  if legacy {
    effects.append(AnyImageEffect(ToneCurveFeature(curves: .init(y: curve("ToneCurvePV2012"),
      red: curve("ToneCurvePV2012Red"), green: curve("ToneCurvePV2012Green"), blue: curve("ToneCurvePV2012Blue")))))
  } else {
    let curves = PointCurveFeature.Curves(master: curve("ToneCurvePV2012"),
      red: curve("ToneCurvePV2012Red"), green: curve("ToneCurvePV2012Green"), blue: curve("ToneCurvePV2012Blue"))
    guard let feature = PointCurveFeature(validatingCurves: curves,
      refineSaturation: number("CurveRefineSaturation", 100)) else { fatalError("Invalid CurveRefineSaturation") }
    effects.append(AnyImageEffect(feature))
  }
}
if adaptive {
  effects.append(AnyImageEffect(TextureFeature(amount: number("Texture"))))
  effects.append(AnyImageEffect(ClarityFeature(amount: number("Clarity2012"))))
  effects.append(AnyImageEffect(DehazeFeature(amount: number("Dehaze"))))
}
if partial {
  var bands = ColorMixerFeature.Bands()
  for (band, key) in zip(ColorMixerFeature.Band.allCases, ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"]) {
    bands[band] = .init(hue: number("HueAdjustment" + key),
      saturation: number("SaturationAdjustment" + key), luminance: number("LuminanceAdjustment" + key))
  }
  effects.append(AnyImageEffect(ColorMixerFeature(bands: bands,
    algorithm: measuredMixer ? .lightroomApproximation : .oklch)))
  // The grading study includes combined wheels. Preserve their authored blend
  // and balance in the same pass instead of measuring each wheel separately.
  if adaptive {
    func correction(_ hue: String, _ saturation: String, _ luminance: String) -> ColorGradingFeature.Correction {
      guard let wheel = ColorGradingFeature.Correction(validatingHue: number(hue),
        saturation: number(saturation), luminance: number(luminance)) else { fatalError("Invalid grading wheel") }
      return wheel
    }
    guard let grading = ColorGradingFeature(
      validatingShadows: correction("SplitToningShadowHue", "SplitToningShadowSaturation", "ColorGradeShadowLum"),
      midtones: correction("ColorGradeMidtoneHue", "ColorGradeMidtoneSat", "ColorGradeMidtoneLum"),
      highlights: correction("SplitToningHighlightHue", "SplitToningHighlightSaturation", "ColorGradeHighlightLum"),
      global: correction("ColorGradeGlobalHue", "ColorGradeGlobalSat", "ColorGradeGlobalLum"),
      blending: number("ColorGradeBlending", 50), balance: number("SplitToningBalance"))
    else { fatalError("Invalid grading blend or balance") }
    effects.append(AnyImageEffect(grading))
  }
  effects += [AnyImageEffect(UnsharpMaskFeature(intensity: number("Sharpness") / 100,
      radius: .absolute(number("SharpenRadius", 1)))),
    AnyImageEffect(VignetteFeature(value: -number("PostCropVignetteAmount") / 50))]
  if includeGrain {
    guard let seed = UInt32(exactly: number("GrainSeed")) else { fatalError("Invalid GrainSeed") }
    effects.append(AnyImageEffect(GrainFeature.CameraRaw(amount: number("GrainAmount"),
      size: number("GrainSize", 25), roughness: number("GrainFrequency", 50), seed: seed)))
  }
}
let image = CIImage(contentsOf: input, options: [.applyOrientationProperty: true])!
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let renderedURL = output.appendingPathComponent("brightroom.png")
let renderStart = ProcessInfo.processInfo.systemUptime
_ = try ExportRenderer().render(from: image, feature: effects,
  options: .init(resolution: .full, outputFormat: .RGBA16,
    outputColorSpace: outputSpace,
    output: .file(url: renderedURL, fileType: .png)))
let renderSeconds = ProcessInfo.processInfo.systemUptime - renderStart
func hash(_ url: URL) throws -> String {
  sha256(try Data(contentsOf: url, options: .mappedIfSafe))
}
var evidence: [String: Any] = ["input": input.path, "inputSHA256": try hash(input),
  "settingsSHA256": try hash(settingsURL), "mode": mode,
  "output": renderedURL.path, "outputSHA256": try hash(renderedURL),
  "renderSecondsIncludesDecodeAndWrite": renderSeconds,
  "workingFormat": "RGBAh", "outputFormat": "16-bit PNG",
  "defaultMetalDevice": MTLCreateSystemDefaultDevice()?.name ?? "unavailable",
  "outputColorSpace": outputSpace.name as String? ?? "embedded ICC",
  "pointCurveSemanticVersion": PointCurveFeature.semanticVersion,
  "unsupportedInPartial": ((measuredLight || tonal) ? [] : ["Whites/Blacks"]) + ["parametric curve", "noise reduction", "Adobe profiles"] + (adaptive ? [] : ["Texture", "Clarity", "Dehaze"]) + (includeGrain ? [] : ["grain"]),
  "mixerAlgorithm": measuredMixer ? "lightroomApproximation" : "oklch",
  "lightModel": measuredLight ? "Measured Whites/Blacks/Saturation; CI Highlights/Shadows" :
    (adaptive ? "Public spatial Highlights/Shadows, adaptive Whites, pointwise Blacks, measured global Saturation" :
      (tonal ? "Public adaptive Whites, pointwise Blacks; CI Highlights/Shadows/Saturation" : "CI Highlights/Shadows/Saturation")),
  "approximatedInPartial": (measuredLight ? ["Whites/Blacks (no image adaptation)"] : (tonal ? ["Whites/Blacks approximation"] : [])) + (adaptive ? ["Texture (local RGB detail)", "Clarity (local contrast SDR approximation)", "Dehaze (scene and neighborhood SDR approximation)"] : []) + ["master point curve", "Mixer", "Highlights/Shadows", "Saturation", "sharpening", "vignette"] + (includeGrain ? ["Grain (texture statistics measured at 20/42/70; Brightroom seed)"] : []),
  "os": ProcessInfo.processInfo.operatingSystemVersionString]
if measuredLight {
  evidence["lightTablesSHA256"] = try hash(URL(fileURLWithPath: CommandLine.arguments[5]))
}
if let outputProfile {
  evidence["outputICCSHA256"] = sha256(outputProfile)
}
try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
  .write(to: output.appendingPathComponent("render.json"))
print(renderedURL.path)
