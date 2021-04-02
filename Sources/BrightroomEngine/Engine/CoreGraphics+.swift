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
  func perform(_ drawing: (CGContext) -> Void) -> CGContext {
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

    let context = try CGContext.init(
      data: nil,
      width: size.map { Int($0.width) } ?? image.width,
      height: size.map { Int($0.height) } ?? image.height,
      bitsPerComponent: image.bitsPerComponent,
      bytesPerRow: 0,
      space: try image.colorSpace.unwrap(),
      bitmapInfo: bitmapInfo.rawValue
    )
    .unwrap()

    return context
  }

  fileprivate func detached(_ perform: () -> Void) {
    saveGState()
    perform()
    restoreGState()
  }
}

extension CGImage {

  var size: CGSize {
    return .init(width: width, height: height)
  }

  func croppedWithColorspace(to cropRect: CGRect) throws -> CGImage {

    let cgImage = try autoreleasepool { () -> CGImage? in

      let context = try CGContext.makeContext(for: self, size: cropRect.size)
        .perform { c in

          c.draw(
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
    try rotated(angle: -rotation.angle, flipping: flipping)
  }
}
