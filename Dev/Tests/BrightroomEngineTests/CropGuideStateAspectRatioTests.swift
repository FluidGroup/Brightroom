import CoreGraphics
import Testing

@testable import BrightroomParametric
@testable import BrightroomUI

/// `CropGuideState` starts an aspect-ratio session for a selection it
/// loaded, keeping one that already has the ratio.
struct CropGuideStateAspectRatioTests {

  private let imageSize = CGSize(width: 400, height: 300)

  private func state(_ rect: CGRect, rotation: QuarterTurn = .zero) -> CropGuideState {
    CropGuideState(imageSize: imageSize, cropRect: rect, rotation: rotation)
  }

  // MARK: - hasAspectRatio

  @Test func `An exact selection has the ratio`() {
    #expect(state(CGRect(x: 10, y: 20, width: 150, height: 150)).hasAspectRatio(.square))
    #expect(state(CGRect(x: 0, y: 0, width: 160, height: 90)).hasAspectRatio(AspectRatio(width: 16, height: 9)))
  }

  /// `CropFeature(topLeftRect:)` moves each edge inward by less than a
  /// pixel, so a stored selection of ratio `r` misses `width == r * height`
  /// by less than `2 * max(1, r)` pixels.
  @Test func `A selection rounded inward to whole pixels has the ratio`() {
    let square = CGRect(x: 0.7, y: 0.2, width: 150.6, height: 150.6)
    let stored = CropFeature(topLeftRect: square, imageSize: imageSize)
    let reloaded = CropGuideState(cropFeature: stored, imageSize: imageSize)
    #expect(reloaded.cropExtent.width != reloaded.cropExtent.height)
    #expect(reloaded.hasAspectRatio(.square))

    #expect(state(CGRect(x: 10, y: 10, width: 200, height: 198.1)).hasAspectRatio(.square))
    #expect(state(CGRect(x: 10, y: 10, width: 198.1, height: 200)).hasAspectRatio(.square))
    let wide = AspectRatio(width: 16, height: 9)
    #expect(state(CGRect(x: 0, y: 0, width: 156.5, height: 90)).hasAspectRatio(wide))
  }

  @Test func `A selection off by the rounding allowance or more lacks the ratio`() {
    #expect(state(CGRect(x: 10, y: 10, width: 200, height: 198)).hasAspectRatio(.square) == false)
    #expect(state(CGRect(x: 10, y: 10, width: 198, height: 200)).hasAspectRatio(.square) == false)
    let wide = AspectRatio(width: 16, height: 9)
    #expect(state(CGRect(x: 0, y: 0, width: 156.4, height: 90)).hasAspectRatio(wide) == false)
    #expect(state(CGRect(x: 0, y: 0, width: 400, height: 300)).hasAspectRatio(.square) == false)
  }

  /// The ratio describes the output, so a sideways selection is compared
  /// with the swapped ratio.
  @Test func `A sideways selection compares with the turned ratio`() {
    let sideways = state(CGRect(x: 0, y: 0, width: 200, height: 150), rotation: .counterclockwise90)
    #expect(sideways.hasAspectRatio(AspectRatio(width: 3, height: 4)))
    #expect(sideways.hasAspectRatio(AspectRatio(width: 4, height: 3)) == false)
  }

  @Test func `A ratio with a zero side matches no selection`() {
    let selection = state(CGRect(x: 0, y: 0, width: 200, height: 150))
    #expect(selection.hasAspectRatio(AspectRatio(width: 0, height: 1)) == false)
    #expect(selection.hasAspectRatio(AspectRatio(width: 1, height: 0)) == false)
  }

  // MARK: - aspectRatioLock

  /// A lock follows the output's turn, as a quarter turn in the canvas
  /// turns it, unless the output already has the lock as it is.
  @Test func `A lock turns with a selection whose output turned, unless the output has it`() {
    let landscape = AspectRatio(width: 4, height: 3)
    // Output 3:4 (selection 4:3): what turning a 4:3-locked crop produces.
    let turned = state(CGRect(x: 0, y: 0, width: 200, height: 150), rotation: .counterclockwise90)
    #expect(turned.aspectRatioLock(landscape, replacingSideways: false) == landscape.swapped())
    // Output 4:3 (selection 3:4): the output already has the lock.
    let turnedWithLock = state(CGRect(x: 0, y: 0, width: 150, height: 200), rotation: .counterclockwise90)
    #expect(turnedWithLock.aspectRatioLock(landscape, replacingSideways: false) == landscape)
    // Neither: the lock turns with the output, as before.
    let turnedWithNeither = state(CGRect(x: 0, y: 0, width: 200, height: 100), rotation: .counterclockwise90)
    #expect(turnedWithNeither.aspectRatioLock(landscape, replacingSideways: false) == landscape.swapped())
    // Same orientation as the replaced selection: the lock is kept.
    let unturned = state(CGRect(x: 0, y: 0, width: 150, height: 200))
    #expect(unturned.aspectRatioLock(landscape, replacingSideways: false) == landscape)
    #expect(turned.aspectRatioLock(landscape.swapped(), replacingSideways: true) == landscape.swapped())
  }

  // MARK: - adoptAspectRatio

  @Test func `Adopting a ratio the selection has keeps it and starts the session`() {
    var selection = state(CGRect(x: 0, y: 0, width: 150, height: 150))
    selection.adoptAspectRatio(.square)
    #expect(selection.cropExtent == CGRect(x: 0, y: 0, width: 150, height: 150))
    #expect(selection._usedAspectRatio == .square)
  }

  @Test func `Adopting a ratio the selection lacks fits it inside the selection`() {
    var selection = state(CGRect(x: 0, y: 0, width: 200, height: 100))
    selection.adoptAspectRatio(.square)
    #expect(selection.cropExtent == CGRect(x: 50, y: 0, width: 100, height: 100))
    #expect(selection._usedAspectRatio == .square)
  }
}
