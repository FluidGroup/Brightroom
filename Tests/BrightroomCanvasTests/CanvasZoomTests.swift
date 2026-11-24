import CoreGraphics
import Foundation
import Testing

@testable import BrightroomUI

/// `ImageEditorCanvas.Zoom`: the zoom a canvas reports, and the fraction of
/// its range that a zoom slider shows and sets.
struct CanvasZoomTests {

  /// From the fit of 0.25 to the maximum of 2 is three doublings.
  private static func zoom(
    scale: CGFloat,
    backingScaleFactor: CGFloat = 2
  ) -> ImageEditorCanvas.Zoom {
    ImageEditorCanvas.Zoom(
      scale: scale,
      fitScale: 0.25,
      maximumScale: 2,
      backingScaleFactor: backingScaleFactor
    )
  }

  private static func scale(atFraction fraction: Double) -> CGFloat {
    ImageEditorCanvas.Zoom.scale(atFraction: fraction, fitScale: 0.25, maximumScale: 2)
  }

  @Test
  func `The fraction runs along the zoom's logarithm, and the scale at a fraction inverts it`() {
    #expect(Self.zoom(scale: 0.25).fraction == 0)
    #expect(abs(Self.zoom(scale: 0.5).fraction - 1.0 / 3) < 1e-12)
    #expect(abs(Self.zoom(scale: 1).fraction - 2.0 / 3) < 1e-12)
    #expect(Self.zoom(scale: 2).fraction == 1)

    #expect(Self.scale(atFraction: 0) == 0.25)
    #expect(abs(Self.scale(atFraction: 1.0 / 3) - 0.5) < 1e-12)
    #expect(Self.scale(atFraction: 1) == 2)
    for fraction in stride(from: 0.0, through: 1.0, by: 0.125) {
      #expect(abs(Self.zoom(scale: Self.scale(atFraction: fraction)).fraction - fraction) < 1e-12)
    }
  }

  @Test
  func `A fraction is clamped to the range`() {
    // A rubber band shows zooms past the limits.
    #expect(Self.zoom(scale: 0.1).fraction == 0)
    #expect(Self.zoom(scale: 5).fraction == 1)

    #expect(Self.scale(atFraction: -1) == 0.25)
    #expect(Self.scale(atFraction: 2) == 2)
  }

  @Test
  func `A degenerate range has a fraction of 0 and stays at its fit`() {
    // A canvas without a size has no zoom range.
    let empty = ImageEditorCanvas.Zoom(
      scale: 0,
      fitScale: 0,
      maximumScale: 0,
      backingScaleFactor: 2
    )
    #expect(empty.fraction == 0)
    #expect(ImageEditorCanvas.Zoom.scale(atFraction: 0.5, fitScale: 0, maximumScale: 0) == 0)

    let flat = ImageEditorCanvas.Zoom(
      scale: 1,
      fitScale: 1,
      maximumScale: 1,
      backingScaleFactor: 2
    )
    #expect(flat.fraction == 0)
    #expect(ImageEditorCanvas.Zoom.scale(atFraction: 0.5, fitScale: 1, maximumScale: 1) == 1)
  }

  @Test
  func `The percent counts device pixels per output pixel`() {
    // A canvas point per output pixel shows each on two device pixels of a
    // Retina display.
    #expect(Self.zoom(scale: 1).percent == 200)
    #expect(Self.zoom(scale: 1, backingScaleFactor: 1).percent == 100)
    #expect(Self.zoom(scale: 0.5).percent == 100)
    // Rounded to a whole percent.
    #expect(Self.zoom(scale: 0.3725, backingScaleFactor: 1).percent == 37)
    #expect(Self.zoom(scale: 0.3751, backingScaleFactor: 1).percent == 38)
  }

  @Test
  func `The percent of a zoom beyond any Int is clamped`() {
    // A 1e-15-pixel crop at an image's top-left corner fits a 300-point
    // canvas at 3e17.
    let zoom = ImageEditorCanvas.Zoom(
      scale: 3e17,
      fitScale: 3e17,
      maximumScale: 2.4e18,
      backingScaleFactor: 2
    )
    #expect(zoom.percent == .max)
  }

  @Test
  func `The zoom tells whether it is at the fit or at the maximum`() {
    #expect(Self.zoom(scale: 0.25).isFitted)
    #expect(Self.zoom(scale: 0.25 * (1 + 1e-7)).isFitted)
    #expect(Self.zoom(scale: 0.25 * (1 + 1e-5)).isFitted == false)
    #expect(Self.zoom(scale: 0.25).isAtMaximum == false)

    #expect(Self.zoom(scale: 2).isAtMaximum)
    #expect(Self.zoom(scale: 2 * (1 - 1e-7)).isAtMaximum)
    #expect(Self.zoom(scale: 2 * (1 - 1e-5)).isAtMaximum == false)
    #expect(Self.zoom(scale: 2).isFitted == false)

    #expect(Self.zoom(scale: 1).isFitted == false)
    #expect(Self.zoom(scale: 1).isAtMaximum == false)
  }
}
