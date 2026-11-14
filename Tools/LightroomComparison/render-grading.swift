// A host-side comparison runner; this is not an XMP storage API in the library.
import BrightroomParametric
import CoreImage
import CryptoKit
import Foundation

precondition(CommandLine.arguments.count == 5,
  "usage: render-grading input-image root-CRS-settings.json output-directory p3|prophoto")
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let settingsURL = URL(fileURLWithPath: CommandLine.arguments[2])
let output = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
precondition(["p3", "prophoto"].contains(CommandLine.arguments[4]), "Expected p3 or prophoto")
let isP3 = CommandLine.arguments[4] == "p3"
precondition(!FileManager.default.fileExists(atPath: output.path), "Evidence must not be overwritten")
let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as! [String: String]
func value(_ key: String, default fallback: Double = 0) -> Double {
  guard let string = settings[key] else { return fallback }
  guard let number = Double(string), number.isFinite else { fatalError("Invalid number: \(key)") }
  return number
}
func correction(_ hue: String, _ saturation: String, _ luminance: String) -> ColorGradingFeature.Correction {
  guard let correction = ColorGradingFeature.Correction(validatingHue: value(hue),
    saturation: value(saturation), luminance: value(luminance)) else {
    fatalError("Invalid grading correction")
  }
  return correction
}
let grading = ColorGradingFeature(
  validatingShadows: correction("SplitToningShadowHue", "SplitToningShadowSaturation", "ColorGradeShadowLum"),
  midtones: correction("ColorGradeMidtoneHue", "ColorGradeMidtoneSat", "ColorGradeMidtoneLum"),
  highlights: correction("SplitToningHighlightHue", "SplitToningHighlightSaturation", "ColorGradeHighlightLum"),
  global: correction("ColorGradeGlobalHue", "ColorGradeGlobalSat", "ColorGradeGlobalLum"),
  blending: value("ColorGradeBlending", default: 50), balance: value("SplitToningBalance"))!
let image = CIImage(contentsOf: input, options: [.applyOrientationProperty: true])!
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let renderedURL = output.appendingPathComponent("brightroom.png")
_ = try ExportRenderer().render(from: image, feature: grading,
  options: .init(resolution: .full, outputFormat: .RGBA16,
    outputColorSpace: CGColorSpace(name: isP3 ? CGColorSpace.displayP3 : CGColorSpace.rommrgb),
    output: .file(url: renderedURL, fileType: .png)))
func hash(_ url: URL) throws -> String {
  SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}
let evidence: [String: Any] = ["input": input.path, "inputSHA256": try hash(input),
  "settings": settings, "settingsSHA256": try hash(settingsURL),
  "output": renderedURL.path, "outputSHA256": try hash(renderedURL),
  "workingFormat": "RGBAh", "outputFormat": "16-bit PNG",
  "outputColorSpace": isP3 ? "Display P3" : "ProPhoto RGB",
  "implementation": "ColorGradingFeature through public ExportRenderer",
  "os": ProcessInfo.processInfo.operatingSystemVersionString]
try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted])
  .write(to: output.appendingPathComponent("render.json"))
print(renderedURL.path)
