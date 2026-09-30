import CoreGraphics
import Testing
import Vision

@testable import BrightroomParametric
@testable import BrightroomUI

/// The crop face detection frames, pinned to the y-down computation it was
/// first written with: the padded face box, normalized, flipped into a
/// top-left crop rectangle by `CropGeometry.cropRect(toFitBoundingBox:)`,
/// then pixel-aligned by `CropFeature(topLeftRect:)`.
///
/// Any other implementation (for example one that stays in Vision's
/// bottom-left space) must produce the same crops.
struct FaceFramingCropTests {

  struct Case: CustomTestStringConvertible, Sendable {
    var name: String
    var imageSize: CGSize
    /// A Vision bounding box: normalized, bottom-left origin.
    var faceBox: CGRect

    var testDescription: String { name }
  }

  static let cases: [Case] = [
    .init(name: "near the top", imageSize: .init(width: 4000, height: 3000), faceBox: .init(x: 0.4, y: 0.8, width: 0.1, height: 0.1)),
    .init(name: "near the bottom", imageSize: .init(width: 4000, height: 3000), faceBox: .init(x: 0.45, y: 0.05, width: 0.1, height: 0.08)),
    .init(name: "centered", imageSize: .init(width: 4000, height: 3000), faceBox: .init(x: 0.42, y: 0.4, width: 0.16, height: 0.2)),
    .init(name: "touching the left edge", imageSize: .init(width: 4000, height: 3000), faceBox: .init(x: 0, y: 0.3, width: 0.1, height: 0.1)),
    .init(name: "touching the top-right corner", imageSize: .init(width: 4000, height: 3000), faceBox: .init(x: 0.85, y: 0.88, width: 0.15, height: 0.12)),
    .init(name: "touching the bottom edge", imageSize: .init(width: 4000, height: 3000), faceBox: .init(x: 0.3, y: 0, width: 0.2, height: 0.15)),
    .init(name: "portrait near the top", imageSize: .init(width: 3000, height: 4000), faceBox: .init(x: 0.35, y: 0.7, width: 0.2, height: 0.15)),
    .init(name: "portrait near the bottom", imageSize: .init(width: 3000, height: 4000), faceBox: .init(x: 0.5, y: 0.1, width: 0.2, height: 0.15)),
    .init(name: "odd size, off-grid box", imageSize: .init(width: 1001, height: 667), faceBox: .init(x: 0.1234, y: 0.6789, width: 0.0987, height: 0.1357)),
    .init(name: "odd size, near the bottom", imageSize: .init(width: 1001, height: 667), faceBox: .init(x: 0.7771, y: 0.0333, width: 0.111, height: 0.0999)),
  ]

  static let aspectRatios: [AspectRatio?] = [
    nil,
    .square,
    .init(width: 4, height: 5),
    .init(width: 16, height: 9),
  ]

  static let paddingBiases: [CGFloat] = [0, 0.5, 1.3, 3]

  @Test(arguments: cases)
  func `Face framing matches the y-down computation`(_ testCase: Case) {
    for aspectRatio in Self.aspectRatios {
      for paddingBias in Self.paddingBiases {
        let framed = CropFeature.framingFace(
          testCase.faceBox,
          imageSize: testCase.imageSize,
          paddingBias: paddingBias,
          aspectRatio: aspectRatio
        )
        let expected = Self.yDownReference(
          testCase.faceBox,
          imageSize: testCase.imageSize,
          paddingBias: paddingBias,
          aspectRatio: aspectRatio
        )
        #expect(
          framed == expected,
          "ratio \(String(describing: aspectRatio)), padding \(paddingBias)"
        )
        #expect(framed.quarterTurn == .zero)
        #expect(framed.straightenRadians == 0)
      }
    }
  }

  @Test func `A face near the top of the picture frames the top`() {
    // Vision's y grows upward, as CropFeature.rect's does.
    let framed = CropFeature.framingFace(
      CGRect(x: 0.4, y: 0.8, width: 0.1, height: 0.1),
      imageSize: CGSize(width: 4000, height: 3000),
      paddingBias: 0.5,
      aspectRatio: nil
    )
    // Face (1600, 2400, 400, 300), padded to (1400, 2250, 800, 600), which
    // is already 4:3.
    #expect(framed.rect == CGRect(x: 1400, y: 2250, width: 800, height: 600))
    #expect(
      framed.topLeftRect(imageSize: CGSize(width: 4000, height: 3000))
        == CGRect(x: 1400, y: 150, width: 800, height: 600)
    )
  }

  @Test func `A face near the bottom of the picture frames the bottom`() {
    let imageSize = CGSize(width: 4000, height: 3000)
    let framed = CropFeature.framingFace(
      CGRect(x: 0.45, y: 0.05, width: 0.1, height: 0.08),
      imageSize: imageSize,
      paddingBias: 0.5,
      aspectRatio: .square
    )
    #expect(framed.rect.midY < imageSize.height / 2)
    #expect(framed.rect.width == framed.rect.height)
  }

  @Test func `A face at the edge is clipped to the image before fitting`() {
    let framed = CropFeature.framingFace(
      CGRect(x: 0, y: 0.3, width: 0.1, height: 0.1),
      imageSize: CGSize(width: 4000, height: 3000),
      paddingBias: 1.3,
      aspectRatio: nil
    )
    // Face (0, 900, 400, 300), padded to (-520, 510, 1440, 1080), clipped to
    // (0, 510, 920, 1080), fitted to 4:3 about its center.
    #expect(framed.rect == CGRect(x: 0, y: 705, width: 920, height: 690))
  }

  /// The computation face detection shipped with, in y-down coordinates.
  private static func yDownReference(
    _ faceBox: CGRect,
    imageSize: CGSize,
    paddingBias: CGFloat,
    aspectRatio: AspectRatio?
  ) -> CropFeature {
    let width = Int(imageSize.width)
    let height = Int(imageSize.height)
    let faceRect = VNImageRectForNormalizedRect(faceBox, width, height)
    let paddedRect = faceRect.insetBy(
      dx: -faceRect.width * paddingBias,
      dy: -faceRect.height * paddingBias
    )
    let boundingBox = VNNormalizedRectForImageRect(paddedRect, width, height)
    let topLeftRect = CropGeometry.cropRect(
      toFitBoundingBox: boundingBox,
      within: CGRect(origin: .zero, size: imageSize),
      in: imageSize,
      straightenRadians: 0,
      respectingAspectRatio: aspectRatio ?? AspectRatio(imageSize)
    )
    return CropFeature(topLeftRect: topLeftRect, imageSize: imageSize)
  }
}
