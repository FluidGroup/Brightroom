// Render the standalone grain effect without changing the A10 adapter's scores.
import BrightroomParametric
import CoreImage
import CryptoKit
import Foundation

precondition(CommandLine.arguments.count == 7,
  "usage: render-grain input output-directory amount radius-pixels roughness seed")
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let amount = Double(CommandLine.arguments[3])!
let radius = Double(CommandLine.arguments[4])!
let roughness = Double(CommandLine.arguments[5])!
let seed = UInt32(CommandLine.arguments[6])!
let grain = GrainFeature(validatingAmount: amount, radius: .absolute(radius), roughness: roughness, seed: seed)!
precondition(!FileManager.default.fileExists(atPath: output.path), "Do not overwrite evidence")
let source = CIImage(contentsOf: input, options: [.applyOrientationProperty: true])!
let space = source.colorSpace!
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let target = output.appendingPathComponent("grain.png")
_ = try ExportRenderer().render(from: source, feature: grain,
  options: .init(resolution: .full, outputFormat: .RGBA16, outputColorSpace: space,
    output: .file(url: target, fileType: .png)))
func hash(_ url: URL) throws -> String {
  SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}
let report: [String: Any] = [
  "input": input.path, "inputSHA256": try hash(input),
  "output": target.path, "outputSHA256": try hash(target),
  "amount": amount, "radiusInFullResolutionPixels": radius, "roughness": roughness, "seed": seed,
  "status": "Procedural grain; no Adobe parameter or seed compatibility claimed",
  "outputFormat": "16-bit PNG", "outputProfile": "same embedded profile as input",
]
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
  .write(to: output.appendingPathComponent("render.json"))
print(target.path)
