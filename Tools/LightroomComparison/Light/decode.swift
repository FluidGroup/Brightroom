// Decode the analytic references in a fixed, ICC-managed Float32 space.
// Row zero in the output is the top row of the source TIFF.
import CoreImage
import CryptoKit
import Foundation
import ImageIO

let arguments = CommandLine.arguments
precondition(arguments.count > 2, "usage: decode-postraw-probes output-directory [--native-pixels] images...")
let includeNativePixels = arguments[2] == "--native-pixels"
let paths = arguments.dropFirst(includeNativePixels ? 3 : 2)
precondition(!paths.isEmpty)
let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
precondition(!FileManager.default.fileExists(atPath: output.path), "evidence already exists")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf,
  .useSoftwareRenderer: true, .cacheIntermediates: false])
var records = [[String: Any]]()
for path in paths {
  let url = URL(fileURLWithPath: path).standardizedFileURL
  let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
  let bitmap = CGImageSourceCreateImageAtIndex(source, 0, nil)!
  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
  precondition(bitmap.bitsPerComponent == 16)
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
  var record: [String: Any] = ["input": url.path, "output": name, "width": bitmap.width,
    "height": bitmap.height, "space": "extended-linear Display-P3 D65",
    "format": "little-endian Float32 RGBA, opaque, top-to-bottom",
    "sha256": SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()]
  if includeNativePixels {
    // Preserve the source codes before ICC conversion so equal-color pairs
    // can be identified independently of the working-space precision.
    precondition(bitmap.colorSpace?.model == .rgb && [48, 64].contains(bitmap.bitsPerPixel))
    let bytes = bitmap.dataProvider!.data! as Data
    precondition(bytes.count == bitmap.bytesPerRow * bitmap.height)
    let native = url.deletingPathExtension().lastPathComponent + ".pixels"
    try bytes.write(to: output.appendingPathComponent(native))
    record["nativePixels"] = native
    record["bytesPerPixel"] = bitmap.bitsPerPixel / 8
    record["bytesPerRow"] = bitmap.bytesPerRow
    switch bitmap.alphaInfo {
    case .first, .premultipliedFirst, .noneSkipFirst:
      record["rgbOffset"] = 2
    case .last, .premultipliedLast, .noneSkipLast, .none:
      record["rgbOffset"] = 0
    default:
      preconditionFailure("Expected an opaque RGB source")
    }
  }
  records.append(record)
}
try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
  .write(to: output.appendingPathComponent("manifest.json"))
print("Decoded \(records.count) references")
