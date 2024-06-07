//
// Copyright (c) 2021 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import CoreGraphics
import ImageIO

extension CGContext {

  @discardableResult
  consuming func perform(_ drawing: (borrowing CGContext) -> Void) -> CGContext {
    drawing(self)
    return self
  }

  static func makeContext(for image: CGImage, size: CGSize? = nil) throws -> CGContext {

    var bitmapInfo = image.bitmapInfo

    /**
     Modifies alpha info in order to solve following issues:

     [For creating CGContext]
     - A screenshot image taken on iPhone might be DisplayP3 16bpc. This is not supported in CoreGraphics.
     https://stackoverflow.com/a/42684334/2753383

     [For MTLTexture]
     - An image loaded from ImageIO seems to contains something different bitmap-info compared with UIImage(named:)
     That causes creating broken MTLTexture, technically texture contains alpha and wrong color format.
     I don't know why it happens.
     */
    bitmapInfo.remove(.alphaInfoMask)
    bitmapInfo.formUnion(.init(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
    /**
     The image from PHImageManager uses `.byteOrder32Little`.
     This is not compatible with MTLTexture.
     */
    bitmapInfo.remove(.byteOrder32Little)

    /**

     Ref: https://github.com/guoyingtao/Mantis/issues/12
     */
    let outputColorSpace: CGColorSpace

    if let colorSpace = image.colorSpace, colorSpace.supportsOutput {
      outputColorSpace = colorSpace
    } else {
      EngineLog.error(.default, "CGImage's color-space does not support output. \(image.colorSpace as Any)")
      outputColorSpace = CGColorSpaceCreateDeviceRGB()
    }

    let width = size.map { Int($0.width) } ?? image.width
    let height = size.map { Int($0.height) } ?? image.height

    if let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: image.bitsPerComponent,
      bytesPerRow: 0,
      space: outputColorSpace,
      bitmapInfo: bitmapInfo.rawValue
    ) {
      return context
    }
    return
      try CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 8 * 4 * image.width,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      ).unwrap()
  }

  fileprivate func detached(_ perform: () -> Void) {
    saveGState()
    perform()
    restoreGState()
  }
}

extension CGContext {

  /**
   around center: use center of boundingBoxOfClipPath
   */
  func rotate(radians: CGFloat, anchor: CGPoint) {

    translateBy(x: anchor.x, y: anchor.y)
    rotate(by: radians)
    translateBy(x: -anchor.x, y: -anchor.y)

  }
}

extension CGImage {

  var size: CGSize {
    return .init(width: width, height: height)
  }

  func croppedWithColorspace(
    to cropRect: CGRect,
    adjustmentAngleRadians: CGFloat
  ) throws -> CGImage {

    let cgImage = try autoreleasepool { () -> CGImage? in

      let context = try CGContext.makeContext(for: self, size: cropRect.size)
        .perform { context in

          context.rotate(
            radians: -adjustmentAngleRadians,
            anchor: .init(x: context.boundingBoxOfClipPath.midX, y: context.boundingBoxOfClipPath.midY)
          )

          context.draw(
            self,
            in: CGRect(
              origin: .init(
                x: -cropRect.origin.x,
                y: -(size.height - cropRect.maxY)
              ),
              size: size
            )
          )

        }
      return context.makeImage()
    }

    return try cgImage.unwrap()

  }

  func resized(maxPixelSize: CGFloat) throws -> CGImage {

    let cgImage = try autoreleasepool { () -> CGImage? in

      let targetSize = Geometry.sizeThatAspectFit(
        size: size,
        maxPixelSize: maxPixelSize
      )

      let context = try CGContext.makeContext(for: self, size: targetSize)
        .perform { c in
          c.interpolationQuality = .high
          c.draw(self, in: c.boundingBoxOfClipPath)
        }
      return context.makeImage()
    }

    return try cgImage.unwrap()
  }

  enum Flipping {
    case vertically
    case horizontally
  }

  func rotated(angle: CGFloat, flipping: Flipping? = nil) throws -> CGImage {
    guard angle != 0 else {
      return self
    }

    var rotatedSize: CGSize =
      size
      .applying(.init(rotationAngle: angle))

    rotatedSize.width = abs(rotatedSize.width)
    rotatedSize.height = abs(rotatedSize.height)

    let cgImage = try autoreleasepool { () -> CGImage? in
      let rotatingContext = try CGContext.makeContext(for: self, size: rotatedSize)
        .perform { c in

          if let flipping = flipping {
            switch flipping {
            case .vertically:
              c.translateBy(x: 0, y: rotatedSize.height)
              c.scaleBy(x: 1, y: -1)
            case .horizontally:
              c.translateBy(x: rotatedSize.width, y: 0)
              c.scaleBy(x: -1, y: 1)
            }
          }

          c.translateBy(x: rotatedSize.width / 2, y: rotatedSize.height / 2)
          c.rotate(by: angle)
          c.translateBy(
            x: -size.width / 2,
            y: -size.height / 2
          )

          c.draw(self, in: .init(origin: .zero, size: self.size))
        }

      return rotatingContext.makeImage()
    }

    return try cgImage.unwrap()
  }

  func oriented(_ orientation: CGImagePropertyOrientation) throws -> CGImage {

    let angle: CGFloat

    switch orientation {
    case .down, .downMirrored:
      angle = CGFloat.pi
    case .left, .leftMirrored:
      angle = CGFloat.pi / 2.0
    case .right, .rightMirrored:
      angle = CGFloat.pi / -2.0
    case .up, .upMirrored:
      angle = 0
    }

    let flipping: Flipping?
    switch orientation {
    case .upMirrored, .downMirrored:
      flipping = .horizontally
    case .leftMirrored, .rightMirrored:
      flipping = .vertically
    case .up, .down, .left, .right:
      flipping = nil
    }

    let result = try rotated(angle: angle, flipping: flipping)

    return result
  }

  func rotated(rotation: EditingCrop.Rotation, flipping: Flipping? = nil)
    throws -> CGImage
  {
    try rotated(angle: -rotation.angle.radians, flipping: flipping)
  }

}

import Metal
import MetalKit
import CoreImage

extension CGImage {

  func _makeCIImage(
    orientation: CGImagePropertyOrientation,
    device: MTLDevice?,
    usesMTLTexture: Bool
  ) -> CIImage {

    let cgImage = self

    let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()

    func createFromCGImage() -> CIImage {
      return CIImage(
        cgImage: cgImage
      )
      .oriented(orientation)
    }

    func createFromMTLTexture(device: MTLDevice) throws -> CIImage {
      let thumbnailTexture = try makeMTLTexture(
        from: cgImage,
        device: device
      )

      let ciImage = try CIImage(
        mtlTexture: thumbnailTexture,
        options: [.colorSpace: colorSpace]
      )
        .map {
          $0.transformed(by: .init(scaleX: 1, y: -1))
        }.map {
          $0.transformed(by: .init(translationX: 0, y: $0.extent.height))
        }
        .map {
          $0.oriented(orientation)
        }
        .unwrap()

      EngineLog.debug(.stack, "Load MTLTexture")

      return ciImage
    }

    if usesMTLTexture {
      assert(device != nil)
    }

    if usesMTLTexture, let device = device {

      do {
        // TODO: As possible, creates CIImage from MTLTexture
        // 16bits image can't be MTLTexture with MTKTextureLoader.
        // https://stackoverflow.com/questions/54710592/cant-load-large-jpeg-into-a-mtltexture-with-mtktextureloader
        return try createFromMTLTexture(device: device)
      } catch {
        EngineLog.debug(
          .stack,
          "Unable to create MTLTexutre, fallback to CIImage from CGImage.\n\(cgImage)"
        )

        return createFromCGImage()
      }
    } else {

      if usesMTLTexture, device == nil {
        EngineLog.error(
          .stack,
          "MTLDevice not found, fallback to using CGImage to create CIImage."
        )
      }

      return createFromCGImage()
    }

  }

}


private enum MTLImageCreationError: Error {
  case imageTooBig
}

extension MTLDevice {
  fileprivate func supportsImage(size: CGSize) -> Bool {
#if DEBUG
    switch MTLGPUFamily.apple1 {
    case .apple1,
        .apple2,
        .apple3,
        .apple4,
        .apple5,
        .apple6,
        .apple7,
        .apple8,
        .apple9,
        .common1,
        .common2,
        .common3,
        .mac1,
        .mac2,
        .macCatalyst1,
        .macCatalyst2,
        .metal3:
      break
    @unknown default:  //If a warning is triggered here, please check https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf for a possibly new value in the Maximum 2D texture width and height table.
      break
    }
#endif
    let maxSideSize: CGFloat = self.supportsFamily(.apple3) ? 16384 : 8192
    return size.width <= maxSideSize && size.height <= maxSideSize
  }
}

/// TODO: As possible, creates CIImage from MTLTexture
/// 16bits image can't be MTLTexture with MTKTextureLoader.
/// https://stackoverflow.com/questions/54710592/cant-load-large-jpeg-into-a-mtltexture-with-mtktextureloader
private func makeMTLTexture(from cgImage: CGImage, device: MTLDevice) throws -> MTLTexture {
  guard device.supportsImage(size: cgImage.size) else {
    throw MTLImageCreationError.imageTooBig
  }

#if true
  let loader = MTKTextureLoader(device: device)
  let texture = try loader.newTexture(cgImage: cgImage, options: [:])
  return texture
#else

  // Here does not work well.

  let textureDescriptor = MTLTextureDescriptor()

  textureDescriptor.pixelFormat = .rgba16Uint
  textureDescriptor.width = cgImage.width
  textureDescriptor.height = cgImage.height

  let texture = try device.makeTexture(descriptor: textureDescriptor).unwrap(
    orThrow: "Failed to create MTLTexture"
  )

  let context = try CGContext.makeContext(for: cgImage)
    .perform { context in
      let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(cgImage.height))
      context.concatenate(flip)
      context.draw(
        cgImage,
        in: CGRect(x: 0, y: 0, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
      )
    }

  let data = try context.data.unwrap()

  texture.replace(
    region: MTLRegionMake2D(0, 0, cgImage.width, cgImage.height),
    mipmapLevel: 0,
    withBytes: data,
    bytesPerRow: 8 * cgImage.width
  )

  return texture
#endif

}
