// Decode the analytic references in a fixed, ICC-managed Float32 space.
// Row zero in the output is the top row of the source TIFF.
import CoreImage
import CryptoKit
import Foundation
import ImageIO

let arguments = CommandLine.arguments
precondition(arguments.count > 2, "usage: decode-postraw-probes output-directory images...")
let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
precondition(!FileManager.default.fileExists(atPath: output.path), "evidence already exists")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf,
  .useSoftwareRenderer: true, .cacheIntermediates: false])
var records = [[String: Any]]()
for path in arguments.dropFirst(2) {
  let url = URL(fileURLWithPath: path).standardizedFileURL
  let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
  let bitmap = CGImageSourceCreateImageAtIndex(source, 0, nil)!
  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
  precondition(bitmap.bitsPerComponent == 16 && bitmap.width == 1024 && bitmap.height == 256)
  precondition(properties[kCGImagePropertyProfileName] != nil)
  precondition((properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
  let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: false])!
  var pixels = [Float](repeating: .nan, count: bitmap.width * bitmap.height * 4)
  context.render(image, toBitmap: &pixels, rowBytes: bitmap.width * 16,
    bounds: image.extent, format: .RGBAf, colorSpace: space)
  precondition(pixels.allSatisfy(\.isFinite), "non-finite/unrendered pixels")
  precondition(stride(from: 3, to: pixels.count, by: 4).allSatisfy { abs(pixels[$0] - 1) < 0.000001 })
  // Core Image bitmap rendering writes the top scanline first. The independent
  // probe generator's ramps and RGB lattice are checked by the analysis script.
  let data = pixels.withUnsafeBytes { Data($0) }
  let name = url.deletingPathExtension().lastPathComponent + ".rgba32f"
  try data.write(to: output.appendingPathComponent(name))
  records.append(["input": url.path, "output": name, "width": bitmap.width,
    "height": bitmap.height, "space": "extended-linear Display-P3 D65",
    "format": "little-endian Float32 RGBA, opaque, top-to-bottom",
    "sha256": SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()])
}
try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
  .write(to: output.appendingPathComponent("manifest.json"))
print("Decoded \(records.count) references")
