import CoreGraphics
import Testing

@testable import BrightroomParametric

/// `CropGeometry.rectEnlarged(toMinimumSide:rect:in:straightenRadians:aspectRatio:)`:
/// growing a selection about its center until the crop aligned from it
/// reaches a minimum side, as ImageEditor's minimum crop size does.
struct CropEnlargementTests {

  private let imageSize = CGSize(width: 1200, height: 900)

  private func enlarged(
    _ rect: CGRect,
    minimum: CGFloat = 128,
    in imageSize: CGSize? = nil,
    straightenRadians: Double = 0,
    aspectRatio: AspectRatio? = nil
  ) -> CGRect {
    CropGeometry.rectEnlarged(
      toMinimumSide: minimum,
      rect: rect,
      in: imageSize ?? self.imageSize,
      straightenRadians: straightenRadians,
      aspectRatio: aspectRatio
    )
  }

  // MARK: - Large enough

  @Test func `A selection that already reaches the minimum is returned as is`() {
    let fractional = CGRect(x: 100.3, y: 50.7, width: 300, height: 200)
    #expect(enlarged(fractional) == fractional)
    let tall = CGRect(x: 10, y: 20, width: 128, height: 300)
    #expect(enlarged(tall, aspectRatio: AspectRatio(tall.size)) == tall)
    let fractionalTall = CGRect(x: 10.2, y: 20.3, width: 128, height: 300)
    #expect(enlarged(fractionalTall, straightenRadians: 0.1) == fractionalTall)
    // Ratio-exact alignment keeps 240 × 135 at any origin.
    let wide = CGRect(x: 100.3, y: 200.6, width: 240, height: 135)
    #expect(enlarged(wide, aspectRatio: AspectRatio(width: 16, height: 9)) == wide)
  }

  @Test func `An invalid selection or minimum is returned as is`() {
    let empty = CGRect(x: 10, y: 10, width: 0, height: 50)
    #expect(enlarged(empty) == empty)
    let small = CGRect(x: 10, y: 10, width: 20, height: 20)
    #expect(enlarged(small, minimum: 0) == small)
    #expect(enlarged(small, minimum: .nan) == small)
    #expect(enlarged(small, aspectRatio: AspectRatio(width: 0, height: 1)) == small)
  }

  // MARK: - Each side on its own

  /// The guide a resize at the maximum zoom used to record: 48.8 px wide,
  /// and 128.08 px high but 127 whole pixels once snapped inward.
  @Test func `Each side whose whole pixels miss the minimum grows to it about the center`() {
    let rect = CGRect(x: 514.6006349206349, y: 386.1942857142857, width: 48.7619047619047, height: 128.0812698412699)
    let result = enlarged(rect)
    #expect(result == CGRect(x: 475, y: 386, width: 128, height: 128))
    #expect(CropFeature(topLeftRect: result, imageSize: imageSize).rect.size == CGSize(width: 128, height: 128))
  }

  @Test func `A side that reaches the minimum keeps its place`() {
    let result = enlarged(CGRect(x: 100.5, y: 100.5, width: 50, height: 400))
    // The center 125.5 puts the origin at 61.5, which rounds to 62.
    #expect(result == CGRect(x: 62, y: 100.5, width: 128, height: 400))
  }

  @Test func `A grown selection stays inside the image`() {
    #expect(enlarged(CGRect(x: 1180, y: 880, width: 15, height: 15)) == CGRect(x: 1072, y: 772, width: 128, height: 128))
    #expect(enlarged(CGRect(x: 0, y: 3, width: 15, height: 15)) == CGRect(x: 0, y: 0, width: 128, height: 128))
  }

  /// A minimum the image cannot hold shrinks as `translatedIntoBounds`
  /// shrinks it (ImageEditor caps its minimum at the image's shorter side).
  @Test func `A minimum larger than the image shrinks to the image`() {
    let result = enlarged(CGRect(x: 10, y: 10, width: 20, height: 20), in: CGSize(width: 100, height: 80))
    #expect(result == CGRect(x: 0, y: 0, width: 80, height: 80))
  }

  @Test func `Random small selections align to at least the minimum`() {
    var generator = SeededGenerator(seed: 0x5EED_0128)
    for _ in 0..<2_000 {
      let size = CGSize(
        width: CGFloat.random(in: 1...300, using: &generator),
        height: CGFloat.random(in: 1...300, using: &generator)
      )
      let rect = CGRect(
        x: CGFloat.random(in: 0...(imageSize.width - size.width), using: &generator),
        y: CGFloat.random(in: 0...(imageSize.height - size.height), using: &generator),
        width: size.width,
        height: size.height
      )
      let before = CropFeature(topLeftRect: rect, imageSize: imageSize).rect.size
      let result = enlarged(rect)
      let after = CropFeature(topLeftRect: result, imageSize: imageSize).rect.size

      #expect(after.width >= 128 && after.height >= 128, "\(rect) → \(result)")
      #expect(CGRect(origin: .zero, size: imageSize).contains(result), "\(rect) → \(result)")
      if before.width >= 128 && before.height >= 128 {
        #expect(result == rect)
      }
      if before.width >= 128 {
        #expect(result.minX == rect.minX && result.width == rect.width, "\(rect) → \(result)")
      } else {
        #expect(result.width == 128, "\(rect) → \(result)")
        #expect(abs(result.midX - rect.midX) <= 0.5 || result.minX == 0 || result.maxX == imageSize.width)
      }
      if before.height >= 128 {
        #expect(result.minY == rect.minY && result.height == rect.height, "\(rect) → \(result)")
      } else {
        #expect(result.height == 128, "\(rect) → \(result)")
        #expect(abs(result.midY - rect.midY) <= 0.5 || result.minY == 0 || result.maxY == imageSize.height)
      }
    }
  }

  // MARK: - Keeping a ratio

  /// A face crop of `.square` that the inward snap left 105×104.
  @Test func `A square grows to exactly the minimum about its center`() {
    let result = enlarged(CGRect(x: 242, y: 68, width: 105, height: 104), aspectRatio: .square)
    // Center (294.5, 120).
    #expect(result == CGRect(x: 231, y: 56, width: 128, height: 128))
  }

  @Test func `A ratio with small terms grows to the smallest whole multiple that reaches the minimum`() {
    // 16:9: 15 × (16, 9), since 14 × 9 = 126.
    let wide = enlarged(CGRect(x: 500, y: 400, width: 160, height: 90), aspectRatio: AspectRatio(width: 16, height: 9))
    #expect(wide == CGRect(x: 460, y: 378, width: 240, height: 135))
    #expect(
      CropFeature(topLeftRect: wide, imageSize: imageSize, aspectRatio: AspectRatio(width: 16, height: 9))
        .topLeftRect(imageSize: imageSize) == wide
    )

    // 4:5: 32 × (4, 5).
    let portrait = enlarged(CGRect(x: 100, y: 100, width: 40, height: 50), aspectRatio: AspectRatio(width: 4, height: 5))
    #expect(portrait == CGRect(x: 56, y: 45, width: 128, height: 160))
  }

  /// A guide zoomed in to a shorter side of 128 under a ratio whose
  /// shorter term does not divide 128 aligns to a smaller multiple, so it
  /// grows to the next one; a ratio whose multiples include 128 does not.
  @Test func `A ratio rectangle whose aligned size misses the minimum grows`() {
    let wide = enlarged(
      CGRect(x: 486.2, y: 386, width: 227.55555555555554, height: 128),
      aspectRatio: AspectRatio(width: 16, height: 9)
    )
    // 227.6 × 128 aligns to 14 × (16, 9) = 224 × 126; 15 × (16, 9) reaches 128.
    #expect(wide.size == CGSize(width: 240, height: 135))
    #expect(abs(wide.midX - (486.2 + 227.55555555555554 / 2)) <= 0.5 && abs(wide.midY - 450) <= 0.5, "\(wide)")

    let standard = enlarged(
      CGRect(x: 514.67, y: 386, width: 170.66666666666666, height: 128),
      aspectRatio: AspectRatio(width: 4, height: 3)
    )
    // 170.7 × 128 aligns to 42 × (4, 3) = 168 × 126; 43 × (4, 3) = 172 × 129.
    #expect(standard.size == CGSize(width: 172, height: 129))

    // Squares and 4:5 have a multiple of exactly 128.
    let square = CGRect(x: 536, y: 386, width: 128, height: 127.99999999999994)
    #expect(enlarged(square, aspectRatio: .square) == square)
    let portrait = CGRect(x: 536.4, y: 370.2, width: 128, height: 160)
    #expect(enlarged(portrait, aspectRatio: AspectRatio(width: 4, height: 5)) == portrait)

    #expect(CropGeometry.smallestShorterSide(reaching: 128, aspectRatio: AspectRatio(width: 16, height: 9)) == 135)
    #expect(CropGeometry.smallestShorterSide(reaching: 128, aspectRatio: AspectRatio(width: 3, height: 4)) == 129)
    #expect(CropGeometry.smallestShorterSide(reaching: 128, aspectRatio: .square) == 128)
    #expect(CropGeometry.smallestShorterSide(reaching: 128, aspectRatio: AspectRatio(width: 1123, height: 794)) == 128)
    #expect(CropGeometry.smallestShorterSide(reaching: 127.5, aspectRatio: nil) == 128)
  }

  /// A ratio with large terms snaps edge by edge, so a 128-pixel side at a
  /// fractional origin aligns to 127 and grows.
  @Test func `A ratio rectangle with large terms whose snapped side misses the minimum grows`() {
    let ratio = AspectRatio(width: 1123, height: 794)
    let result = enlarged(CGRect(x: 100.4, y: 100.4, width: 128 * 1123 / 794, height: 128), aspectRatio: ratio)
    #expect(result.size == CGSize(width: 181, height: 128))
    #expect(result.minX == result.minX.rounded() && result.minY == result.minY.rounded(), "\(result)")
    #expect(CropFeature(topLeftRect: result, imageSize: imageSize).rect.size == CGSize(width: 181, height: 128))
  }

  @Test func `A ratio with large terms grows to the nearest whole pixels`() {
    let wide = enlarged(
      CGRect(x: 100, y: 100, width: 112.3, height: 79.4),
      aspectRatio: AspectRatio(width: 1123, height: 794)
    )
    // 128 × 1.41436… = 181.04.
    #expect(wide == CGRect(x: 66, y: 76, width: 181, height: 128))

    let tall = enlarged(
      CGRect(x: 100, y: 100, width: 79.4, height: 112.3),
      aspectRatio: AspectRatio(width: 794, height: 1123)
    )
    #expect(tall.size == CGSize(width: 128, height: 181))
  }

  @Test func `A ratio's multiple is at most the largest the image holds`() {
    // 16:9 needs 14 × 9 = 126 ≥ 120 high, but the 200-pixel-wide image
    // holds 12 × 16 = 192 at most.
    let result = enlarged(
      CGRect(x: 50, y: 30, width: 64, height: 36),
      minimum: 120,
      in: CGSize(width: 200, height: 120),
      aspectRatio: AspectRatio(width: 16, height: 9)
    )
    #expect(result == CGRect(x: 0, y: 0, width: 192, height: 108))
  }

  /// A rectangle as large as the image holds at its ratio is under the
  /// minimum but cannot grow; it is kept, not shrunk to the multiple below.
  @Test func `A rectangle as large as the image holds is not shrunk`() {
    // A 16:9 crop filling a 100 × 100 image (minimum 100): 6 × 16 = 96 is
    // the largest multiple the image holds, which 100 × 56 already has.
    let wide = CGRect(x: 0, y: 22, width: 100, height: 56)
    #expect(
      enlarged(wide, minimum: 100, in: CGSize(width: 100, height: 100), aspectRatio: AspectRatio(width: 16, height: 9))
        == wide
    )

    // A 9:16 crop the full height of a 3000 × 200 image: 12 × 16 = 192.
    let tall = CGRect(x: 1444, y: 0, width: 112, height: 200)
    #expect(
      enlarged(tall, in: CGSize(width: 3000, height: 200), aspectRatio: AspectRatio(width: 9, height: 16))
        == tall
    )

    // The same in a 1000 × 120 image (minimum 120): 7 × 16 = 112.
    let thin = CGRect(x: 467, y: 0, width: 66, height: 120)
    #expect(
      enlarged(thin, minimum: 120, in: CGSize(width: 1000, height: 120), aspectRatio: AspectRatio(width: 9, height: 16))
        == thin
    )
  }

  @Test(arguments: [
    AspectRatio.square,
    AspectRatio(width: 4, height: 5),
    AspectRatio(width: 16, height: 9),
    AspectRatio(width: 3, height: 4),
  ])
  func `Random small selections of a ratio grow to an exact multiple`(ratio: AspectRatio) throws {
    let terms = try #require(PixelAlignedCrop.exactTerms(of: ratio))
    let shorterTerm = min(terms.width, terms.height)
    let multiple = (128 + shorterTerm - 1) / shorterTerm
    var generator = SeededGenerator(seed: 0x4A71_0128)
    for _ in 0..<1_000 {
      let shorter = CGFloat.random(in: 1..<128, using: &generator)
      let size = ratio.width <= ratio.height
        ? CGSize(width: shorter, height: shorter * ratio.height / ratio.width)
        : CGSize(width: shorter * ratio.width / ratio.height, height: shorter)
      let rect = CGRect(
        x: CGFloat.random(in: 0...(imageSize.width - size.width), using: &generator),
        y: CGFloat.random(in: 0...(imageSize.height - size.height), using: &generator),
        width: size.width,
        height: size.height
      )
      let result = enlarged(rect, aspectRatio: ratio)

      #expect(result.size == CGSize(width: multiple * terms.width, height: multiple * terms.height), "\(rect) → \(result)")
      #expect(result.minX == result.minX.rounded() && result.minY == result.minY.rounded(), "\(rect) → \(result)")
      #expect(CGRect(origin: .zero, size: imageSize).contains(result), "\(rect) → \(result)")
      #expect(
        CropFeature(topLeftRect: result, imageSize: imageSize, aspectRatio: ratio).topLeftRect(imageSize: imageSize)
          == result,
        "\(rect) → \(result)"
      )
    }
  }

  // MARK: - Straightened

  @Test func `A straightened selection grows about its center inside the straightened bounds`() {
    let rect = CGRect(x: 500.3, y: 400.7, width: 60, height: 50)
    let result = enlarged(rect, straightenRadians: 0.1)
    #expect(result.size == CGSize(width: 128, height: 128))
    #expect(abs(result.midX - rect.midX) < 1e-9 && abs(result.midY - rect.midY) < 1e-9)
    let aligned = CropFeature(topLeftRect: result, imageSize: imageSize, straightenRadians: 0.1)
    #expect(aligned.rect.size == CGSize(width: 128, height: 128))

    let square = enlarged(rect, straightenRadians: 0.1, aspectRatio: .square)
    #expect(square.size == CGSize(width: 128, height: 128))
  }

  @Test func `A straightened selection near the edge moves inside`() {
    let rect = CGRect(x: 1150, y: 850, width: 40, height: 40)
    let result = enlarged(rect, straightenRadians: 0.1)
    #expect(result.size == CGSize(width: 128, height: 128))
    #expect(
      result == CropGeometry.translatedIntoBounds(
        rect: CGRect(x: rect.midX - 64, y: rect.midY - 64, width: 128, height: 128),
        in: imageSize,
        straightenRadians: 0.1
      )
    )
  }
}

/// A deterministic SplitMix64 generator, so random cases repeat.
private struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
