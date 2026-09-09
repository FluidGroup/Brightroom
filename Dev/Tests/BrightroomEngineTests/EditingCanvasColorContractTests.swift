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

import CoreGraphics
import CoreImage
import Foundation
import Metal
import Testing

@testable import BrightroomUI

/// Display-independent guard for the editing-canvas wide-gamut color contract.
///
/// The simulator (and CI) cannot DISPLAY wide gamut or EDR, so the on-screen
/// fidelity can only be verified on a real P3 device. What CAN be tested
/// anywhere is the COLOR MATH: a Display-P3 primary pushed through a CIContext
/// configured like the canvas must survive, where the old sRGB/8-bit contract
/// clamped it. This test renders the same P3-red through the new contract and
/// the old contract, both encoded into a common Display-P3 buffer, and asserts
/// the new path stays saturated while the old path desaturates — so a
/// regression back to sRGB clamping fails here, not silently in the field.
struct EditingCanvasColorContractTests {

  private let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!
  private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

  /// The four boundary contracts must keep COLOR content wide-gamut. (The mask
  /// contract is intentionally sRGB — a [0,1] selection field, not color.)
  @Test func `Color contracts are wide gamut`() {
    #expect(
      EditingCanvasImageProcessing.workingColorSpace.isWideGamutRGB,
      "working space must be wide-gamut so P3 chroma survives filtering"
    )
    #expect(
      EditingCanvasImageProcessing.intermediateColorSpace.isWideGamutRGB,
      "intermediate texture space must be wide-gamut and match the working space"
    )
    #expect(
      EditingCanvasImageProcessing.drawableColorSpace.isWideGamutRGB,
      "drawable space must be wide-gamut (Display-P3)"
    )
    // The intermediate round-trip is lossless only if write-space == read-space
    // == working-space. Assert they are the same color space.
    #expect(
      EditingCanvasImageProcessing.workingColorSpace.name
        == EditingCanvasImageProcessing.intermediateColorSpace.name,
      "intermediate space must equal the working space for a lossless round-trip"
    )
  }

  /// The Simulator compositor is not a reliable target for the 10-bit drawable
  /// used on device. Keep the display fallback explicit while preserving the
  /// wide-gamut math contract tested below.
  @Test func `Drawable pixel format is simulator safe`() {
    #if targetEnvironment(simulator)
    #expect(EditingCanvasImageProcessing.drawablePixelFormat == .bgra8Unorm)
    #else
    #expect(EditingCanvasImageProcessing.drawablePixelFormat == .bgr10a2Unorm)
    #endif
  }

  /// The canvas contract preserves an out-of-sRGB-gamut Display-P3 red, while the
  /// previous sRGB-working/8-bit contract clamps it (visible as desaturation once
  /// both are expressed in the same Display-P3 space).
  @Test func `Canvas contract preserves Display-P3 red where sRGB contract clamps`() throws {
    // A pure Display-P3 red — its chroma lies OUTSIDE the sRGB gamut.
    let p3Red = CIImage(
      color: CIColor(red: 1, green: 0, blue: 0, colorSpace: displayP3)!
    )
    .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))

    // New canvas contract: extended-linear Display-P3 working space + half-float.
    let canvasContext = CIContext(options: [
      .workingColorSpace: EditingCanvasImageProcessing.workingColorSpace,
      .workingFormat: EditingCanvasImageProcessing.workingFormat,
    ])
    // Old contract: sRGB working space + 8-bit (what the canvas used before).
    let legacyContext = CIContext(options: [
      .workingColorSpace: sRGB,
      .workingFormat: CIFormat.RGBA8,
    ])

    // Encode BOTH results into Display-P3 so they are directly comparable.
    let canvasPixel = renderPixel(p3Red, context: canvasContext, outputColorSpace: displayP3)
    let legacyPixel = renderPixel(p3Red, context: legacyContext, outputColorSpace: displayP3)

    // New contract keeps P3 red ~pure: red maxed, green/blue near zero.
    #expect(canvasPixel.r > 250, "canvas contract should keep P3 red at full red")
    #expect(canvasPixel.g < 12, "canvas contract should not bleed green into P3 red")
    #expect(canvasPixel.b < 12, "canvas contract should not bleed blue into P3 red")

    // Old contract clamps P3 red into the sRGB gamut; expressed back in P3 the
    // sRGB red primary is visibly desaturated (green/blue rise).
    #expect(
      legacyPixel.g > 20,
      "sanity: the legacy sRGB contract should desaturate P3 red (else the test proves nothing)"
    )

    // The fix must preserve strictly more saturation than the old contract.
    #expect(
      Int(canvasPixel.g) < Int(legacyPixel.g),
      "canvas contract must preserve more P3 saturation than the legacy sRGB contract"
    )
  }

  private func renderPixel(
    _ image: CIImage,
    context: CIContext,
    outputColorSpace: CGColorSpace
  ) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
    var pixel = [UInt8](repeating: 0, count: 4)
    context.render(
      image,
      toBitmap: &pixel,
      rowBytes: 4,
      bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
      format: .RGBA8,
      colorSpace: outputColorSpace
    )
    return (pixel[0], pixel[1], pixel[2], pixel[3])
  }
}
