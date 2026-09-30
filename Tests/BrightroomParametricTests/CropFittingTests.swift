import CoreGraphics
import Testing

@testable import BrightroomParametric

/// `CropFeature.pixelAligned(imageSize:)` and `CropFeature.fitted(to:imageSize:)`.
struct CropFittingTests {

  private let imageSize = CGSize(width: 300, height: 200)

  // MARK: - pixelAligned

  @Test func `Pixel alignment snaps the edges inward in y-up coordinates`() {
    let crop = CropFeature(rect: CGRect(x: 10.4, y: 20.6, width: 100.2, height: 50.9))

    let aligned = crop.pixelAligned(imageSize: imageSize)

    // x 10.4...110.6 → 11...110, y 20.6...71.5 → 21...71.
    #expect(aligned.rect == CGRect(x: 11, y: 21, width: 99, height: 50))
  }

  @Test func `Pixel alignment clips the selection to the input`() {
    let crop = CropFeature(
      rect: CGRect(x: -20, y: -10, width: 400, height: 300),
      quarterTurn: .counterclockwise90
    )

    let aligned = crop.pixelAligned(imageSize: imageSize)

    #expect(aligned.rect == CGRect(origin: .zero, size: imageSize))
    #expect(aligned.quarterTurn == .counterclockwise90)
  }

  @Test(arguments: [0, 0.2, -0.35])
  func `Pixel alignment matches the top-left initializer and keeps its angles`(straightenRadians: Double) {
    let topLeftRect = CGRect(x: 30.3, y: 12.7, width: 180.5, height: 120.25)
    let viaTopLeft = CropFeature(
      topLeftRect: topLeftRect,
      imageSize: imageSize,
      quarterTurn: .counterclockwise270,
      straightenRadians: straightenRadians
    )
    let raw = CropFeature(
      rect: CGRect(
        x: topLeftRect.minX,
        y: imageSize.height - topLeftRect.maxY,
        width: topLeftRect.width,
        height: topLeftRect.height
      ),
      quarterTurn: .counterclockwise270,
      straightenRadians: straightenRadians
    )

    let aligned = raw.pixelAligned(imageSize: imageSize)

    #expect(aligned == viaTopLeft)
    #expect(aligned.quarterTurn == .counterclockwise270)
    #expect(aligned.straightenRadians == straightenRadians)
    #expect(aligned.isPixelEquivalent(to: raw, imageSize: imageSize))
  }

  @Test(arguments: [0, 0.2, -0.35])
  func `Pixel alignment leaves an aligned crop unchanged`(straightenRadians: Double) {
    let aligned = CropFeature(
      rect: CGRect(x: 17.25, y: 9.5, width: 201.75, height: 133.1),
      straightenRadians: straightenRadians
    )
    .pixelAligned(imageSize: imageSize)

    #expect(aligned.pixelAligned(imageSize: imageSize) == aligned)
  }

  // MARK: - fitted

  @Test func `Fitting centers the largest selection of the ratio`() {
    let crop = CropFeature(rect: CGRect(x: 10, y: 10, width: 40, height: 30))

    let fitted = crop.fitted(to: .square, imageSize: imageSize)

    // The current rect is not used: the result is re-centered in the image.
    #expect(fitted.rect == CGRect(x: 50, y: 0, width: 200, height: 200))
    #expect(fitted.quarterTurn == .zero)
    #expect(fitted.straightenRadians == 0)
  }

  @Test(arguments: [QuarterTurn.counterclockwise90, .counterclockwise270])
  func `Fitting a sideways crop describes the output ratio`(quarterTurn: QuarterTurn) {
    let crop = CropFeature(rect: CGRect(origin: .zero, size: imageSize), quarterTurn: quarterTurn)

    let fitted = crop.fitted(to: AspectRatio(width: 4, height: 5), imageSize: imageSize)

    // The 4:5 output is a 5:4 selection before the turn.
    #expect(fitted.rect == CGRect(x: 25, y: 0, width: 250, height: 200))
    #expect(fitted.quarterTurn == quarterTurn)
    let output = fitted.outputGeometry(in: .zero).outputBounds.size
    #expect(output == CGSize(width: 200, height: 250))
  }

  @Test func `Fitting a straightened crop keeps its footprint inside the input`() {
    let straightenRadians = 0.25
    let crop = CropFeature(
      rect: CGRect(origin: .zero, size: imageSize),
      quarterTurn: .counterclockwise180,
      straightenRadians: straightenRadians
    )

    let fitted = crop.fitted(to: .square, imageSize: imageSize)

    #expect(fitted.straightenRadians == straightenRadians)
    #expect(fitted.quarterTurn == .counterclockwise180)
    #expect(abs(fitted.rect.width - fitted.rect.height) < 1)
    #expect(abs(fitted.rect.midX - imageSize.width / 2) < 0.5)
    #expect(abs(fitted.rect.midY - imageSize.height / 2) < 0.5)
    // Already aligned: the straightened footprint fits the input.
    #expect(fitted.pixelAligned(imageSize: imageSize) == fitted)
    let expected = CropFeature(
      topLeftRect: CropGeometry.cropRect(
        toFitAspectRatio: .square,
        in: imageSize,
        straightenRadians: straightenRadians
      ),
      imageSize: imageSize,
      quarterTurn: .counterclockwise180,
      straightenRadians: straightenRadians
    )
    #expect(fitted == expected)
  }
}
