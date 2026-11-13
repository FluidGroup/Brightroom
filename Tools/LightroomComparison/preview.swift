// Display-only, ICC-managed sRGB previews. These 8-bit JPEGs are never measured.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

precondition(CommandLine.arguments.count == 3, "usage: preview input output.jpg")
let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil)!
let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
  kCGImageSourceCreateThumbnailFromImageAlways: true,
  kCGImageSourceCreateThumbnailWithTransform: true,
  kCGImageSourceThumbnailMaxPixelSize: 1600,
] as CFDictionary)!
let context = CGContext(data: nil, width: image.width, height: image.height,
  bitsPerComponent: 8, bytesPerRow: image.width * 4,
  space: CGColorSpace(name: CGColorSpace.sRGB)!,
  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
let target = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[2]) as CFURL,
  UTType.jpeg.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(target, context.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
precondition(CGImageDestinationFinalize(target))
