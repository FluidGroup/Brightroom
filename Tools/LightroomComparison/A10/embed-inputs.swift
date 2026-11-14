// Metadata-only test inputs. All cases retain their source's decoded pixels.
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

let manifestURL = URL(fileURLWithPath: CommandLine.arguments[1])
let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
let cases = manifest["cases"] as! [[String: Any]]
var evidence = [[String: Any]]()
for item in cases {
  try autoreleasepool {
    let input = URL(fileURLWithPath: item["input"] as! String)
    let output = URL(fileURLWithPath: item["prepared"] as! String)
    precondition(!FileManager.default.fileExists(atPath: output.path), "Do not overwrite evidence")
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    let source = CGImageSourceCreateWithURL(input as CFURL, nil)!
    let original = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    let pixels = original.dataProvider!.data! as Data
    let metadata = CGImageMetadataCreateFromXMPData(try Data(contentsOf:
      URL(fileURLWithPath: item["settings"] as! String)) as CFData)!
    let writer = CGImageDestinationCreateWithURL(output as CFURL, UTType.tiff.identifier as CFString, 1, nil)!
    var error: Unmanaged<CFError>?
    guard CGImageDestinationCopyImageSource(writer, source,
      [kCGImageDestinationMetadata: metadata] as CFDictionary, &error) else {
      fatalError("Metadata copy failed: \(String(describing: error?.takeRetainedValue()))")
    }
    let copied = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(output as CFURL, nil)!, 0, nil)!
    precondition(pixels == copied.dataProvider!.data! as Data)
    precondition(copied.colorSpace?.name == original.colorSpace?.name && copied.bitsPerComponent == 16)
    evidence.append(["id": item["id"]!, "path": output.path,
      "decodedPixelSHA256": SHA256.hash(data: pixels).map { String(format: "%02x", $0) }.joined(),
      "fileSHA256": SHA256.hash(data: try Data(contentsOf: output)).map { String(format: "%02x", $0) }.joined(),
      "width": copied.width, "height": copied.height, "bits": copied.bitsPerComponent,
      "profile": copied.colorSpace!.name! as String])
  }
}
try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
  .write(to: manifestURL.deletingLastPathComponent().appendingPathComponent("inputs.json"))
print("Verified identical decoded pixels for \(cases.count) cases")
