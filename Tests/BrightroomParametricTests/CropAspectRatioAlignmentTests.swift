import CoreGraphics
import CoreImage
import Testing

@testable import BrightroomParametric

/// `CropFeature(topLeftRect:imageSize:quarterTurn:straightenRadians:aspectRatio:)`:
/// whole-pixel alignment of a selection drawn under an aspect-ratio lock.
struct CropAspectRatioAlignmentTests {

  private let imageSize = CGSize(width: 1000, height: 800)

  /// The output size of `crop`, after its quarter turn.
  private func outputSize(of crop: CropFeature) -> CGSize {
    crop.outputGeometry(in: .zero).outputBounds.size
  }

  // MARK: - Terms

  @Test func `Ratios in any scale reduce to their lowest whole-number terms`() {
    func terms(_ width: CGFloat, _ height: CGFloat) -> [Int]? {
      PixelAlignedCrop.exactTerms(of: AspectRatio(width: width, height: height)).map { [$0.width, $0.height] }
    }

    #expect(terms(1, 1) == [1, 1])
    #expect(terms(16, 9) == [16, 9])
    #expect(terms(9, 16) == [9, 16])
    #expect(terms(4, 5) == [4, 5])
    #expect(terms(1.5, 1) == [3, 2])
    #expect(terms(10, 8) == [5, 4])
    #expect(terms(4032, 3024) == [4, 3])
    #expect(terms(32, 9) == [32, 9])
    #expect(terms(1, 32) == [1, 32])
  }

  @Test func `Ratios with a term above the bound, or no ratio, have no exact terms`() {
    #expect(PixelAlignedCrop.exactTerms(of: AspectRatio(width: 1123, height: 794)) == nil)
    #expect(PixelAlignedCrop.exactTerms(of: AspectRatio(width: 33, height: 1)) == nil)
    #expect(PixelAlignedCrop.exactTerms(of: AspectRatio(width: 1179, height: 2556)) == nil)
    #expect(PixelAlignedCrop.exactTerms(of: AspectRatio(width: 1.91, height: 1)) == nil)
    #expect(PixelAlignedCrop.exactTerms(of: AspectRatio(width: 0, height: 1)) == nil)
    #expect(PixelAlignedCrop.exactTerms(of: AspectRatio(width: 1, height: 0)) == nil)
    #expect(PixelAlignedCrop.exactTerms(of: AspectRatio(width: .nan, height: 1)) == nil)
  }

  // MARK: - Exact ratios

  /// The case edge-by-edge snapping gets wrong: x 0.1…479.6 snaps to
  /// 1…479 (478 px), y 0…479.5 to 0…479 (479 px).
  @Test func `A square selection that snaps to 478 by 479 becomes a square`() {
    let selection = CGRect(x: 0.1, y: 0, width: 479.5, height: 479.5)
    let edgeByEdge = CropFeature(topLeftRect: selection, imageSize: imageSize)
    #expect(edgeByEdge.rect.size == CGSize(width: 478, height: 479))

    let crop = CropFeature(topLeftRect: selection, imageSize: imageSize, aspectRatio: .square)

    #expect(crop.topLeftRect(imageSize: imageSize) == CGRect(x: 0, y: 0, width: 479, height: 479))
  }

  static let exactCases: [(ratio: AspectRatio, turn: QuarterTurn)] = [
    (.square, .zero),
    (AspectRatio(width: 4, height: 5), .zero),
    (AspectRatio(width: 16, height: 9), .zero),
    (.square, .counterclockwise90),
    (AspectRatio(width: 4, height: 5), .counterclockwise90),
    (AspectRatio(width: 16, height: 9), .counterclockwise270),
    (AspectRatio(width: 16, height: 9), .counterclockwise180),
  ]

  /// Fractional selections of the locked ratio, as a guide records them,
  /// align to an output of exactly that ratio: the largest whole multiple of
  /// the terms inside the selection, at a whole-pixel origin within half a
  /// pixel of the centered one, inside the image.
  @Test(arguments: exactCases)
  func `A locked selection aligns to exactly its ratio`(ratio: AspectRatio, turn: QuarterTurn) throws {
    let terms = try #require(PixelAlignedCrop.exactTerms(of: ratio))
    let selectionRatio = turn.isSideways ? ratio.swapped() : ratio
    var generator = SeededGenerator(state: 7)

    for index in 0..<2_000 {
      // Up to the largest selection of the ratio in the image.
      let largest = selectionRatio.sizeThatFits(in: imageSize)
      let width = CGFloat.random(in: 40...largest.width, using: &generator)
      let size = CGSize(width: width, height: width * selectionRatio.height / selectionRatio.width)
      let selection = CGRect(
        x: CGFloat.random(in: 0...(imageSize.width - size.width), using: &generator),
        y: CGFloat.random(in: 0...(imageSize.height - size.height), using: &generator),
        width: size.width,
        height: size.height
      )

      let crop = CropFeature(
        topLeftRect: selection,
        imageSize: imageSize,
        quarterTurn: turn,
        aspectRatio: ratio
      )
      let aligned = crop.topLeftRect(imageSize: imageSize)
      let output = outputSize(of: crop)
      let description = "case \(index): \(selection) → \(aligned), output \(output)"

      // Exactly the ratio, as a whole multiple of its terms.
      let multiple = Int(output.width) / terms.width
      #expect(output == CGSize(width: multiple * terms.width, height: multiple * terms.height), "\(description)")

      // The largest multiple inside the whole-pixel size of the selection.
      let available = (width: Int(floor(selection.width)), height: Int(floor(selection.height)))
      let selectionTerms = turn.isSideways ? (width: terms.height, height: terms.width) : terms
      #expect(Int(aligned.width) <= available.width && Int(aligned.height) <= available.height, "\(description)")
      #expect(
        (multiple + 1) * selectionTerms.width > available.width
          || (multiple + 1) * selectionTerms.height > available.height,
        "\(description)"
      )

      // Whole pixels, centered within half a pixel, inside the image.
      #expect(aligned.origin.x == aligned.origin.x.rounded() && aligned.origin.y == aligned.origin.y.rounded(), "\(description)")
      #expect(abs(aligned.midX - selection.midX) <= 0.5 + 1e-9, "\(description)")
      #expect(abs(aligned.midY - selection.midY) <= 0.5 + 1e-9, "\(description)")
      #expect(CGRect(origin: .zero, size: imageSize).contains(aligned), "\(description)")

      // Aligned already: edge-by-edge snapping leaves it as it is.
      #expect(crop.pixelAligned(imageSize: imageSize) == crop, "\(description)")
    }
  }

  @Test func `A locked selection past the image edge aligns inside the image`() {
    // 16:9, 320 × 180, 0.3 px past the right edge.
    let selection = CGRect(x: imageSize.width - 319.7, y: 100.25, width: 320, height: 180)

    let crop = CropFeature(
      topLeftRect: selection,
      imageSize: imageSize,
      aspectRatio: AspectRatio(width: 16, height: 9)
    )

    // Inside the image the selection is 319.7 wide: 319 whole pixels, so
    // 19 × (16:9) = 304 × 171.
    let aligned = crop.topLeftRect(imageSize: imageSize)
    #expect(aligned.size == CGSize(width: 304, height: 171))
    #expect(aligned.maxX <= imageSize.width)
    #expect(aligned.origin.x == aligned.origin.x.rounded())
  }

  @Test(arguments: [0.1, -0.2])
  func `A straightened locked selection aligns to exactly its ratio about its fitted center`(
    straightenRadians: Double
  ) {
    let ratio = AspectRatio(width: 4, height: 5)
    let selection = CGRect(x: 300.3, y: 200.7, width: 240.5, height: 300.625)

    let crop = CropFeature(
      topLeftRect: selection,
      imageSize: imageSize,
      straightenRadians: straightenRadians,
      aspectRatio: ratio
    )
    let edgeByEdge = CropFeature(
      topLeftRect: selection,
      imageSize: imageSize,
      straightenRadians: straightenRadians
    )

    // 240 × 300 fits in 240.5 × 300.625: 60 × (4:5). The selection is inside
    // the straightened image, so the center is the selection's.
    let aligned = crop.topLeftRect(imageSize: imageSize)
    #expect(aligned.size == CGSize(width: 240, height: 300))
    #expect(abs(aligned.midX - selection.midX) < 1e-9)
    #expect(abs(aligned.midY - selection.midY) < 1e-9)
    #expect(crop.straightenRadians == straightenRadians)
    #expect(edgeByEdge.rect.size == CGSize(width: 240, height: 300))
    #expect(crop.pixelAligned(imageSize: imageSize) == crop)
  }

  @Test func `A straightened locked selection past the source keeps the fitted shrink and an exact ratio`() {
    // The whole image at 0.1 rad does not fit: it shrinks about its center.
    let selection = CGRect(origin: .zero, size: imageSize)

    let crop = CropFeature(
      topLeftRect: selection,
      imageSize: imageSize,
      straightenRadians: 0.1,
      aspectRatio: AspectRatio(width: 5, height: 4)
    )

    let aligned = crop.topLeftRect(imageSize: imageSize)
    let fitted = CropGeometry.fittingStraightenedRect(rect: selection, in: imageSize, straightenRadians: 0.1)
    let multiple = Int(aligned.width) / 5
    #expect(aligned.size == CGSize(width: multiple * 5, height: multiple * 4), "\(aligned)")
    #expect(aligned.width <= floor(fitted.width) && aligned.height <= floor(fitted.height), "\(aligned) in \(fitted)")
    #expect(
      CGFloat((multiple + 1) * 5) > floor(fitted.width) || CGFloat((multiple + 1) * 4) > floor(fitted.height),
      "\(aligned) in \(fitted)"
    )
    #expect(abs(aligned.midX - fitted.midX) < 1e-9 && abs(aligned.midY - fitted.midY) < 1e-9)
  }

  // MARK: - Snapped edge by edge

  @Test func `A ratio with large terms snaps edge by edge`() {
    let ratio = AspectRatio(width: 1123, height: 794)
    let selection = CGRect(x: 10.4, y: 20.6, width: 561.5, height: 397)

    let crop = CropFeature(topLeftRect: selection, imageSize: imageSize, aspectRatio: ratio)

    #expect(crop == CropFeature(topLeftRect: selection, imageSize: imageSize))
    let size = crop.rect.size
    #expect(abs(size.width - size.height * ratio.width / ratio.height) < 2, "\(size)")
  }

  @Test func `A selection smaller than the terms snaps edge by edge`() {
    let selection = CGRect(x: 3.5, y: 4.5, width: 15.5, height: 8.7)

    let crop = CropFeature(
      topLeftRect: selection,
      imageSize: imageSize,
      aspectRatio: AspectRatio(width: 16, height: 9)
    )

    #expect(crop == CropFeature(topLeftRect: selection, imageSize: imageSize))
  }

  @Test func `An invalid selection snaps edge by edge`() {
    for selection in [
      CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
      CGRect(x: 2000, y: 2000, width: 100, height: 100),
    ] {
      let crop = CropFeature(topLeftRect: selection, imageSize: imageSize, aspectRatio: .square)
      #expect(crop == CropFeature(topLeftRect: selection, imageSize: imageSize), "\(selection)")
    }
  }

  // MARK: - Rendering

  @Test(arguments: exactCases)
  func `A locked crop renders exactly its ratio`(ratio: AspectRatio, turn: QuarterTurn) throws {
    let selectionRatio = turn.isSideways ? ratio.swapped() : ratio
    let selection = CGRect(
      x: 123.37,
      y: 77.81,
      width: 401.13,
      height: 401.13 * selectionRatio.height / selectionRatio.width
    )
    let crop = CropFeature(
      topLeftRect: selection,
      imageSize: imageSize,
      quarterTurn: turn,
      aspectRatio: ratio
    )
    let source = CIImage(color: .gray).cropped(to: CGRect(origin: .zero, size: imageSize))

    let rendered = try FeatureRenderer().makeImage(from: source, feature: crop)

    let size = rendered.extent.size
    #expect(size.width == size.width.rounded() && size.height == size.height.rounded(), "\(size)")
    #expect(abs(size.width * ratio.height - size.height * ratio.width) < 1e-9, "\(size)")
  }
}

/// A deterministic SplitMix64 generator, so random cases repeat.
private struct SeededGenerator: RandomNumberGenerator {
  var state: UInt64

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }
}
