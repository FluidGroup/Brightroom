// Capture the local range statistics consumed by the public Highlights and Shadows kernel.
import CoreImage
import CryptoKit
import Foundation
import Metal
import simd

/// A registered input TIFF and its row-major UInt32 sample positions.
private struct Request: Decodable {
  let source: String
  let input: String
  let indices: String
}

let args = CommandLine.arguments
let captureSourceColor = args.count == 5 && ["--source-color", "--highlight-color"].contains(args[4])
let capturePositiveShadows = args.count == 5 && args[4] == "--positive-shadows"
precondition(args.count == 4 || captureSourceColor || capturePositiveShadows,
  "usage: capture-tone-range product.metallib requests.json new-directory [--source-color | --positive-shadows]")
let library = try Data(contentsOf: URL(fileURLWithPath: args[1]))
private let requests = try JSONDecoder().decode([Request].self,
  from: Data(contentsOf: URL(fileURLWithPath: args[2])))
let folder = URL(fileURLWithPath: args[3], isDirectory: true)
precondition(!FileManager.default.fileExists(atPath: folder.path))
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
let context = CIContext(mtlDevice: MTLCreateSystemDefaultDevice()!, options: [
  .workingColorSpace: space, .workingFormat: CIFormat.RGBAh,
  .highQualityDownsample: true, .cacheIntermediates: false,
])
let luminance = try CIColorKernel(functionName: "brightroomToneLuminance", fromMetalLibraryData: library)
let deviations = try CIKernel(functionName: "brightroomToneDeviations", fromMetalLibraryData: library)

for request in requests {
  try autoreleasepool {
    let url = URL(fileURLWithPath: request.input)
    let hash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    precondition(hash == request.source)
    let indices = try Data(contentsOf: URL(fileURLWithPath: request.indices)).withUnsafeBytes {
      Array($0.bindMemory(to: UInt32.self))
    }
    let source = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])!.matchedFromWorkingSpace(to: space)!
    let factor = min(1, 512 / max(source.extent.width, source.extent.height))
    let area = source.extent.applying(.init(scaleX: factor, y: factor))
    let width = Int(source.extent.width), height = Int(source.extent.height)
    var pixels = [SIMD4<Float>](repeating: .zero, count: width * height)
    func samples(_ image: CIImage) -> [SIMD3<Float>] {
      context.render(image, toBitmap: &pixels, rowBytes: width * 16,
        bounds: source.extent, format: .RGBAf, colorSpace: space)
      return indices.map { index in
        let p = pixels[Int(index)]
        precondition(p.x.isFinite && p.y.isFinite && p.z.isFinite && p.w.isFinite)
        // A scaled guide can end on a fractional pixel at the edge of a photo.
        // The public kernel normalizes by the sampled coverage at that location.
        return SIMD3(p.x, p.y, p.z) / max(p.w, 1e-8)
      }
    }
    func average(_ image: CIImage) -> CIImage {
      image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: area)])
    }
    func value(_ image: CIImage) -> SIMD4<Float> {
      var pixel = SIMD4<Float>.zero
      context.render(image, toBitmap: &pixel, rowBytes: 16, bounds: image.extent, format: .RGBAf, colorSpace: space)
      precondition(pixel.w > 0.99)
      return pixel / pixel.w
    }
    let colors = samples(source).map { simd_clamp($0, .zero, .init(repeating: 1)) }
    let inputY = colors.map { simd_dot($0, SIMD3(0.22897456, 0.69173852, 0.07928692)) }
    let controls = capturePositiveShadows ? [("Shadows2012", 3)] : [("Highlights2012", 0), ("Shadows2012", 2)]
    for (name, control) in controls {
      if captureSourceColor && control != 0 { continue }
      let raw = luminance.apply(extent: source.extent, arguments: [source, Float(control)])!
      let guide = raw.clampedToExtent().applyingFilter("CILanczosScaleTransform",
        parameters: [kCIInputScaleKey: factor, "inputAspectRatio": 1]).cropped(to: area)
      func blur(_ radius: CGFloat) -> CIImage {
        guide.clampedToExtent().applyingFilter("CIGaussianBlur",
          parameters: [kCIInputRadiusKey: radius * max(area.width, area.height) / 1024]).cropped(to: area)
      }
      let mean = average(guide)
      let variance = deviations.apply(extent: area, roiCallback: { index, rect in index == 2 ? mean.extent : rect },
        arguments: [guide, blur(4), mean])!
      let globalRange = value(mean).z
      let stats = value(average(variance))
      let deviation = sqrt(max(0, stats.y))
      if capturePositiveShadows {
        let region = samples(blur(64).transformed(by: .init(scaleX: 1 / factor, y: 1 / factor)))
        var rows = [SIMD4<Float>]()
        rows.reserveCapacity(indices.count)
        for i in indices.indices {
          rows.append(SIMD4(stats.x, deviation, sqrt(max(0, stats.z)), region[i].x))
        }
        try rows.withUnsafeBytes { Data($0) }.write(to: folder.appendingPathComponent("\(hash)-lift.f32"))
        continue
      }
      if captureSourceColor {
        // Both negative controls use these source colors and log-luminance statistics.
        // Only the guide's third channel varies with the control.
        let activity = sqrt(max(0, stats.z))
        var result = [Float]()
        result.reserveCapacity(colors.count * 6)
        for color in colors {
          result.append(contentsOf: [color.x, color.y, color.z, stats.x, deviation, activity])
        }
        try result.withUnsafeBytes { Data($0) }.write(to: folder.appendingPathComponent("\(hash)-color.f32"))
        continue
      }
      let nearby = [16, 64, 256].map { radius in
        samples(blur(CGFloat(radius)).transformed(by: .init(scaleX: 1 / factor, y: 1 / factor))).map(\.z)
      }
      var result = [Float]()
      result.reserveCapacity(indices.count * 6)
      for index in indices.indices {
        result.append(contentsOf: [inputY[index], nearby[0][index], nearby[1][index], nearby[2][index], globalRange, deviation])
      }
      try result.withUnsafeBytes { Data($0) }.write(to: folder.appendingPathComponent("\(hash)-\(name).f32"))
    }
  }
}
