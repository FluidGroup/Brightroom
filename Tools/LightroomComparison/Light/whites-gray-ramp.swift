// Measure the public +50 response with the color lattice's luminance and room in every color channel.
import BrightroomParametric
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Metal

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let input = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])!
precondition(input.extent == CGRect(x: 0, y: 0, width: 1024, height: 256))
let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
let context = CIContext(mtlDevice: MTLCreateSystemDefaultDevice()!, options: [
  .workingColorSpace: linearP3, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false,
])
let luminance = CIVector(x: 0.2289746, y: 0.6917385, z: 0.0792869, w: 0)
let gray = CIFilter.colorMatrix()
gray.inputImage = input
gray.rVector = luminance
gray.gVector = luminance
gray.bVector = luminance
let source = gray.outputImage!
let output = try FeatureRenderer().makeImage(from: source, feature: WhitesFeature(amount: 50))

// The upper ramp runs from 0 through 1023. Every 33rd sample is also a gray node of the 32³ lattice.
func grayCodes(in image: CIImage) -> [Double] {
  var pixels = [SIMD4<Float>](repeating: .zero, count: 1024)
  context.render(image, toBitmap: &pixels, rowBytes: pixels.count * 16,
    bounds: CGRect(x: 0, y: 255 - 32, width: 1024, height: 1), format: .RGBAf, colorSpace: linearP3)
  return stride(from: 0, through: 1023, by: 33).map { x in
    let y = Double(pixels[x].y)
    return y <= 0.0031308 ? 12.92 * y : 1.055 * pow(y, 1 / 2.4) - 0.055
  }
}

let start = grayCodes(in: source)
let end = grayCodes(in: output)
print(String(decoding: try JSONEncoder().encode(["neutral": start, "whites50": end]), as: UTF8.self))
