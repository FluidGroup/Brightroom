//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
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

import CoreImage
import BrightroomEngine
import BrightroomParametric
import Metal
import simd

/// A standalone, testable wrapper around the **live** canvas's way of drawing a
/// brush mask: one off-screen `BrushStampPipeline` pass into an 8-bit texture,
/// wrapped with `CIImage(mtlTexture:)`.
///
/// `EditingCanvasRenderer` drives the same pipeline inline for live painting,
/// where the encoding is interleaved with viewport math, drawable management,
/// and stroke state. This type keeps only the texture pass, so tests can prove
/// that a mask drawn the canvas way lands exactly where the export draws it
/// through Core Image tiles (`FeatureGraphCompiler.renderMask`). Both use
/// `BrushStampPipeline`; what the test pins is the coordinate mapping and
/// orientation of the two targets.
struct BrushMaskMetalRasterizer {

  /// One soft circular stamp to rasterize. `center` and `pixelRadius` are in
  /// canvas pixels (the identity / no-viewport domain — see `rasterize`).
  struct Stamp {
    var center: CGPoint
    var pixelRadius: CGFloat
    var hardness: Float
    var opacity: Float

    init(center: CGPoint, pixelRadius: CGFloat, hardness: Float, opacity: Float) {
      self.center = center
      self.pixelRadius = pixelRadius
      self.hardness = hardness
      self.opacity = opacity
    }
  }

  private let device: MTLDevice
  private let commandQueue: MTLCommandQueue
  private let pipeline: MTLRenderPipelineState

  /// Builds the brush-mask pipeline on `device`. Returns `nil` if a command
  /// queue, the shader library, or the pipeline state cannot be created.
  init?(device: MTLDevice) {
    guard let commandQueue = device.makeCommandQueue() else {
      return nil
    }
    do {
      let pipeline = try BrushStampPipeline.renderPipelineState(
        device: device,
        pixelFormat: .rgba8Unorm
      )
      self.device = device
      self.commandQueue = commandQueue
      self.pipeline = pipeline
    } catch {
      return nil
    }
  }

  /// Rasterizes `stamps` into an `.rgba8Unorm` texture of `canvasPixelSize` and
  /// returns it as a `CIImage` cropped to that extent.
  ///
  /// Coordinates are the **identity (no-viewport)** domain: `center` is in
  /// canvas pixels and the vertex shader maps it to clip space. There is no
  /// content→view scale here, so this matches `FeatureGraphCompiler.renderMask`
  /// where the stamp center is given directly in the mask extent.
  ///
  /// ## Orientation — no extra flip is needed
  ///
  /// `brushStampVertex` maps the center to clip space with
  /// `clip.y = 1 - center.y / targetSize.y * 2` (so `center.y = 0` → clip `+1` →
  /// texture row 0). `CIImage(mtlTexture:)` then treats row 0 as the bottom of
  /// the image (Metal top-left origin → Core Image bottom-left origin). Those
  /// two flips compose: a stamp passed with `center = (x, y)` lands at CI-y `y`
  /// in the wrapped image — exactly where the export's Core Image tiles
  /// (`BrushMaskImageProcessor`, which flips into a tile whose row 0 is
  /// `region.maxY`) place the same `y`.
  /// So the wrapped texture is already in `renderMask`'s frame and is directly
  /// comparable to the export/preview mask without any added transform.
  /// (The live view's `renderDrawableImage` flip is a separate, drawable-only
  /// presentation step and does not belong here.)
  func rasterize(stamps: [Stamp], canvasPixelSize: CGSize) -> CIImage? {
    let width = Int(canvasPixelSize.width.rounded())
    let height = Int(canvasPixelSize.height.rounded())
    guard width > 0, height > 0 else {
      return nil
    }

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm,
      width: width,
      height: height,
      mipmapped: false
    )
    descriptor.usage = [.shaderRead, .renderTarget]
    descriptor.storageMode = .shared

    guard
      let texture = device.makeTexture(descriptor: descriptor),
      let commandBuffer = commandQueue.makeCommandBuffer()
    else {
      return nil
    }

    let passDescriptor = MTLRenderPassDescriptor()
    passDescriptor.colorAttachments[0].texture = texture
    passDescriptor.colorAttachments[0].loadAction = .clear
    passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    passDescriptor.colorAttachments[0].storeAction = .store

    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
      return nil
    }

    encoder.setRenderPipelineState(pipeline)

    BrushStampPipeline.encode(
      stamps.map {
        BrushStampPipeline.Stamp(
          center: SIMD2(Float($0.center.x), Float($0.center.y)),
          radius: Float($0.pixelRadius),
          hardness: $0.hardness,
          opacity: $0.opacity
        )
      },
      targetSize: SIMD2(Float(width), Float(height)),
      into: encoder
    )

    encoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

    let extent = CGRect(origin: .zero, size: CGSize(width: width, height: height))
    guard
      let textureImage = CIImage(
        mtlTexture: texture,
        options: [.colorSpace: EditingCanvasImageProcessing.maskColorSpace]
      )
    else {
      return nil
    }

    // No extra flip: `brushStampVertex` puts `center.y` on texture row `y`, and
    // `CIImage(mtlTexture:)` treats row 0 as the bottom of the image, so the
    // stamp lands at Core Image y = the input y — the coordinate
    // `renderMask` uses. So the wrapped texture is already in `renderMask`'s
    // frame.
    return textureImage.cropped(to: extent)
  }
}
