// Extract ICC/precision evidence and root XMP without rendering or applying it.
import CryptoKit
import Foundation
import ImageIO

precondition(CommandLine.arguments.count > 2, "usage: inspect new-output-directory images...")
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
precondition(!FileManager.default.fileExists(atPath: output.path), "Do not overwrite evidence")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var records = [[String: Any]]()
for path in CommandLine.arguments.dropFirst(2) {
  try autoreleasepool {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    // Inspect and hash one snapshot so a later file change cannot mix evidence.
    let input = try Data(contentsOf: url)
    let source = CGImageSourceCreateWithData(input as CFData, nil)!
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
    precondition(image.bitsPerComponent == 16 && properties[kCGImagePropertyProfileName] != nil)
    precondition((properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
    let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil)!
    let xmp = CGImageMetadataCreateXMPData(metadata, nil)! as Data
    let metadataURL = output.appendingPathComponent(url.lastPathComponent + ".metadata.xmp")
    try xmp.write(to: metadataURL)
    let profile = image.colorSpace!.copyICCData()! as Data
    let profileURL = output.appendingPathComponent(url.lastPathComponent + ".icc")
    try profile.write(to: profileURL)
    records.append(["input": url.path, "width": image.width, "height": image.height,
      "bits": image.bitsPerComponent, "profile": properties[kCGImagePropertyProfileName]!,
      "alphaInfo": image.alphaInfo.rawValue,
      // Bind the extracted packet to this inspection, not just its filename.
      // These hashes detect changed evidence; they do not sign its provenance.
      "metadata": metadataURL.path,
      "metadataSHA256": SHA256.hash(data: xmp).map { String(format: "%02x", $0) }.joined(),
      "icc": profileURL.path,
      "iccSHA256": SHA256.hash(data: profile).map { String(format: "%02x", $0) }.joined(),
      "sha256": SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()])
  }
}
try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
  .write(to: output.appendingPathComponent("images.json"))
print("Inspected \(records.count) images")
