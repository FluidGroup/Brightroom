import CoreGraphics
import CoreImage
import Testing
import UIKit

@testable import BrightroomEngine
@testable import BrightroomParametric
@testable import BrightroomUI

/// Pins that a quarter-turned crop commits and exports the frame CropView shows.
///
/// `CropView.rotateClockwise()` keeps the crop frame's center in image
/// coordinates and takes the output orientation, so the frame of a full-image
/// crop turned a quarter extends past the unrotated image bounds: it is
/// `(W/2 - H/2, H/2 - W/2, H, W)` in y-down display space. `CropFeature.apply`
/// rotates the image about that center, which fills the frame exactly.
///
/// The regression these guard: the engine snapper clamped that rect to the
/// UNROTATED image bounds, so Done committed and exported a centered H×H square
/// instead of the whole rotated image.
@MainActor
struct QuarterTurnCropTests {

  /// A landscape source of 50 px cells (6×4 here), each a distinct color.
  private let imageSize = CGSize(width: 300, height: 200)

  private static let cellSize: CGFloat = 50

  // MARK: - Full-image crop

  @Test(arguments: [QuarterTurn.quarterCW, .half, .quarterCCW])
  func `Turning the full image exports the whole rotated image`(rotation: QuarterTurn) async throws {
    let stack = try makeStack(size: imageSize)
    let initial = try #require(stack.featureTree?.finalCrop)

    // What CropView does: turn the frame about its center.
    var crop = CropEditingState(cropFeature: initial, imageSize: imageSize)
    crop.updateCropExtent(Self.turnedAboutCenter(crop.cropExtent, from: crop.rotation, to: CropRotation(rotation)))
    crop.rotation = CropRotation(rotation)

    let isSideways = rotation == .quarterCW || rotation == .quarterCCW
    let expectedExtent = isSideways
      ? CGRect(x: 50, y: -50, width: 200, height: 300)
      : CGRect(origin: .zero, size: imageSize)

    // Done: CropView commits through `makeCropFeature()`.
    let committed = try commit(crop, to: stack)
    #expect(committed.displayCropRect(imageSize: imageSize) == expectedExtent)
    #expect(committed.rotation == rotation)

    // Export.
    let rendered = try await stack.makeRenderer().render().cgImage
    #expect(rendered.width == Int(expectedExtent.width))
    #expect(rendered.height == Int(expectedExtent.height))
    let checked = try Self.expectRendered(
      rendered,
      showsSourceOfSize: imageSize,
      croppedTo: expectedExtent,
      rotationRadians: rotation.radians
    )
    // Every source cell is in the output: nothing was cut away.
    #expect(checked == Self.cellCount(in: imageSize))
    try Self.expectEveryPixelIsACellColor(rendered)

    // Reopening the editor seeds the same frame, not a clamped one.
    let reseeded = CropEditingState(cropFeature: committed, imageSize: imageSize)
    #expect(reseeded.cropExtent == expectedExtent)
    #expect(reseeded.isRenderingEquivalent(to: crop))
  }

  /// When `W - H` is odd, the turned frame would sit on half pixels, where a
  /// quarter turn resamples every pixel between two source pixels. The snapper
  /// trims one source column instead, so the export stays pixel-exact.
  @Test func `Turning an odd-parity image stays pixel-exact`() async throws {
    let size = CGSize(width: 301, height: 200)
    let stack = try makeStack(size: size)
    let initial = try #require(stack.featureTree?.finalCrop)

    var crop = CropEditingState(cropFeature: initial, imageSize: size)
    crop.updateCropExtent(Self.turnedAboutCenter(crop.cropExtent, from: .angle_0, to: .angle_90))
    crop.rotation = .angle_90

    let committed = try commit(crop, to: stack)
    let expectedExtent = CGRect(x: 50, y: -50, width: 200, height: 300)
    #expect(committed.displayCropRect(imageSize: size) == expectedExtent)

    // Re-committing the stored crop is a fixed point.
    let reseeded = CropEditingState(cropFeature: committed, imageSize: size)
    #expect(reseeded.makeCropFeature().cropRect == committed.cropRect)

    let rendered = try await stack.makeRenderer().render().cgImage
    #expect(rendered.width == 200)
    #expect(rendered.height == 300)
    let checked = try Self.expectRendered(
      rendered,
      showsSourceOfSize: size,
      croppedTo: expectedExtent,
      rotationRadians: QuarterTurn.quarterCW.radians
    )
    // Only the trimmed 1 px column of cells is missing.
    #expect(checked == Self.cellCount(in: CGSize(width: 300, height: 200)))
    try Self.expectEveryPixelIsACellColor(rendered)
  }

  // MARK: - Quarter turn + straighten

  @Test func `Quarter turn with straighten keeps the frame`() async throws {
    let stack = try makeStack(size: imageSize)
    let initial = try #require(stack.featureTree?.finalCrop)

    // A 180×280 frame about the image center: turned back by 90° + 2° its
    // footprint (≈286×190) still lies inside the 300×200 source.
    let extent = CGRect(x: 60, y: -40, width: 180, height: 280)
    var crop = CropEditingState(cropFeature: initial, imageSize: imageSize)
    crop.rotation = .angle_90
    crop.adjustmentAngle = .degrees(2)
    crop.updateCropExtent(extent)

    let committed = try commit(crop, to: stack)
    #expect(committed.displayCropRect(imageSize: imageSize) == extent)

    let rendered = try await stack.makeRenderer().render().cgImage
    #expect(rendered.width == 180)
    #expect(rendered.height == 280)
    let checked = try Self.expectRendered(
      rendered,
      showsSourceOfSize: imageSize,
      croppedTo: extent,
      rotationRadians: committed.aggregatedRotationRadians
    )
    #expect(checked > 0)
  }

  // MARK: - Non-full crop after a quarter turn

  @Test func `A partial crop after a quarter turn keeps its frame`() async throws {
    let stack = try makeStack(size: imageSize)
    let initial = try #require(stack.featureTree?.finalCrop)

    // Off-center and taller than the unrotated image. Its footprint on the
    // source, (50, 40, 240, 120), is inside the image, so nothing clamps.
    let extent = CGRect(x: 110, y: -20, width: 120, height: 240)
    var crop = CropEditingState(cropFeature: initial, imageSize: imageSize)
    crop.rotation = .angle_90
    crop.updateCropExtent(extent)

    let committed = try commit(crop, to: stack)
    #expect(committed.displayCropRect(imageSize: imageSize) == extent)
    #expect(CropEditingState(cropFeature: committed, imageSize: imageSize).cropExtent == extent)

    let rendered = try await stack.makeRenderer().render().cgImage
    #expect(rendered.width == 120)
    #expect(rendered.height == 240)
    let checked = try Self.expectRendered(
      rendered,
      showsSourceOfSize: imageSize,
      croppedTo: extent,
      rotationRadians: QuarterTurn.quarterCW.radians
    )
    #expect(checked > 0)
  }

  @Test func `A quarter-turned crop past the image clamps its footprint`() {
    // Footprint of this frame on the source: (50, -60, 240, 120), 60 px above
    // the image. Only that overhang goes, in the source orientation:
    // (50, 0, 240, 60), turned back about its center (170, 30).
    let feature = CropFeature(
      displayCropRect: CGRect(x: 110, y: -120, width: 120, height: 240),
      imageSize: imageSize,
      rotation: .quarterCW
    )
    #expect(
      feature.displayCropRect(imageSize: imageSize)
        == CGRect(x: 140, y: -90, width: 60, height: 240)
    )
  }

  /// A malformed stored crop: its rect overlaps the image, but its center, and
  /// with it the whole sideways footprint, lies outside. Reopening it clamps
  /// the rect first, as 5.1.0 did, and then the footprint.
  @Test func `Reopening a turned crop centered outside the image clamps it`() {
    // Display rect (-40, 0, 60, 10), center (-10, 5). Its footprint,
    // (-15, -25, 10, 60), misses the image entirely.
    let stored = CropFeature(
      cropRect: CGRect(x: -40, y: 190, width: 60, height: 10),
      rotation: .quarterCW
    )

    let reopened = CropEditingState(cropFeature: stored, imageSize: imageSize)

    // The rect clamped to the image, (0, 0, 20, 10), has its footprint
    // (5, -5, 10, 20) partly above the image: that overhang goes, leaving the
    // footprint (5, 0, 10, 15), turned back about its center (10, 7.5).
    #expect(reopened.cropExtent == CGRect(x: 2.5, y: 2.5, width: 15, height: 10))
  }

  /// `CropView.rotateClockwise()` swaps a locked aspect ratio and refits the
  /// frame after setting the new rotation. The fit uses the turned image, so a
  /// 3:2 lock on a 3:2 image still keeps the whole image after a quarter turn.
  @Test func `A locked aspect ratio refits against the turned image`() {
    var crop = CropEditingState(
      cropFeature: CropFeature.test(imageSize: imageSize),
      imageSize: imageSize
    )
    crop.rotation = .angle_90
    crop.updateCropExtent(toFitAspectRatio: .init(width: 2, height: 3))

    #expect(crop.cropExtent == CGRect(x: 50, y: -50, width: 200, height: 300))
    #expect(
      crop.makeCropFeature().displayCropRect(imageSize: imageSize)
        == CGRect(x: 50, y: -50, width: 200, height: 300)
    )
  }

  @Test func `An unrotated crop still clamps to the image`() {
    let feature = CropFeature(
      displayCropRect: CGRect(x: 50, y: -50, width: 200, height: 300),
      imageSize: imageSize
    )
    #expect(
      feature.displayCropRect(imageSize: imageSize)
        == CGRect(x: 50, y: 0, width: 200, height: 200)
    )
  }

  // MARK: - Helpers

  /// Commits a working crop the way `CropView.applyDocumentChanges()` does.
  private func commit(_ crop: CropEditingState, to stack: EditingStack) throws -> CropFeature {
    let feature = crop.makeCropFeature()
    #expect(
      stack.updateFeature(id: EditingFeatureTree.finalCropNodeID) { node in
        var feature = feature
        feature.id = EditingFeatureTree.finalCropNodeID
        node = .domain(feature)
      }
    )
    return try #require(stack.featureTree?.finalCrop)
  }

  /// Mirrors `CropView`'s `CGRect.rotated(_:)`: the rect turned about its own
  /// center.
  private static func turnedAboutCenter(
    _ rect: CGRect,
    from current: CropRotation,
    to next: CropRotation
  ) -> CGRect {
    let turned = rect.applying(.init(rotationAngle: current.angle.radians - next.angle.radians))
    return CGRect(
      x: rect.minX - (turned.width - rect.width) / 2,
      y: rect.minY - (turned.height - rect.height) / 2,
      width: turned.width,
      height: turned.height
    )
  }

  private func makeStack(size: CGSize) throws -> EditingStack {
    let cgImage = try Self.makeCellImage(size: size)
    let sourceCIImage = CIImage(cgImage: cgImage)
    let initialEdit = EditingStack.Edit.test(imageSize: size)
    let loaded = EditingStack.Loaded(
      imageSource: ImageSource(cgImage: cgImage),
      metadata: .init(orientation: .up, imageSize: size),
      initialEditing: initialEdit,
      currentEdit: initialEdit,
      thumbnailCIImage: sourceCIImage,
      editingSourceCGImage: cgImage,
      editingSourceCIImage: sourceCIImage
    )
    let stack = EditingStack(imageProvider: .init(image: UIImage(cgImage: cgImage)))
    stack.loadedState = loaded
    return stack
  }

  private static func cellCount(in size: CGSize) -> Int {
    Int((size.width / cellSize).rounded(.up)) * Int((size.height / cellSize).rounded(.up))
  }

  private static func cellColor(column: Int, row: Int) -> (red: UInt8, green: UInt8, blue: UInt8) {
    (UInt8(30 + 37 * column), UInt8(40 + 60 * row), 90)
  }

  /// A source whose 50 px cells each have a distinct color (y-down rows).
  private static func makeCellImage(size: CGSize) throws -> CGImage {
    let width = Int(size.width)
    let height = Int(size.height)
    let context = try #require(
      CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
          | CGImageAlphaInfo.premultipliedLast.rawValue
      )
    )
    // Flip to y-down so cell row 0 is the top of the image.
    context.translateBy(x: 0, y: size.height)
    context.scaleBy(x: 1, y: -1)
    for column in 0..<Int((size.width / cellSize).rounded(.up)) {
      for row in 0..<Int((size.height / cellSize).rounded(.up)) {
        let color = cellColor(column: column, row: row)
        context.setFillColor(
          red: CGFloat(color.red) / 255,
          green: CGFloat(color.green) / 255,
          blue: CGFloat(color.blue) / 255,
          alpha: 1
        )
        context.fill(CGRect(
          x: CGFloat(column) * cellSize,
          y: CGFloat(row) * cellSize,
          width: cellSize,
          height: cellSize
        ))
      }
    }
    return try #require(context.makeImage())
  }

  /// Checks the rendered crop against the source, independently of the
  /// engine's crop snapper.
  ///
  /// Each source cell center is mapped forward through the crop geometry the
  /// compiler evaluates (in y-up space: rotate by `-rotationRadians` about the
  /// crop-rect center, then translate the crop origin to zero). Where it lands
  /// inside the render, the pixel must be that cell's color.
  ///
  /// - Returns: The number of cell centers that landed inside the render.
  @discardableResult
  private static func expectRendered(
    _ rendered: CGImage,
    showsSourceOfSize size: CGSize,
    croppedTo displayRect: CGRect,
    rotationRadians: Double,
    sourceLocation: SourceLocation = #_sourceLocation
  ) throws -> Int {
    let pixels = try rgbaPixels(of: rendered)
    let cropRectYUp = CGRect(
      x: displayRect.minX,
      y: size.height - displayRect.maxY,
      width: displayRect.width,
      height: displayRect.height
    )
    let center = CGPoint(x: cropRectYUp.midX, y: cropRectYUp.midY)
    let transform = CGAffineTransform(translationX: center.x, y: center.y)
      .rotated(by: -rotationRadians)
      .translatedBy(x: -center.x, y: -center.y)
      .concatenating(.init(translationX: -cropRectYUp.minX, y: -cropRectYUp.minY))

    var checked = 0
    for column in 0..<Int((size.width / cellSize).rounded(.up)) {
      for row in 0..<Int((size.height / cellSize).rounded(.up)) {
        let cellMaxX = min(CGFloat(column + 1) * cellSize, size.width)
        let cellMaxY = min(CGFloat(row + 1) * cellSize, size.height)
        let sourceYDown = CGPoint(
          x: (CGFloat(column) * cellSize + cellMaxX) / 2,
          y: (CGFloat(row) * cellSize + cellMaxY) / 2
        )
        let output = CGPoint(x: sourceYDown.x, y: size.height - sourceYDown.y)
          .applying(transform)
        let x = Int(output.x.rounded(.down))
        let y = rendered.height - 1 - Int(output.y.rounded(.down))
        guard (1..<(rendered.width - 1)).contains(x), (1..<(rendered.height - 1)).contains(y) else {
          continue
        }
        checked += 1

        let expected = cellColor(column: column, row: row)
        let offset = (y * rendered.width + x) * 4
        let actual = (pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3])
        #expect(
          abs(Int(actual.0) - Int(expected.red)) <= 12
            && abs(Int(actual.1) - Int(expected.green)) <= 12
            && abs(Int(actual.2) - Int(expected.blue)) <= 12
            && actual.3 == 255,
          "cell (\(column), \(row)) at (\(x), \(y)): got \(actual), expected \(expected)",
          sourceLocation: sourceLocation
        )
      }
    }
    return checked
  }

  /// Every rendered pixel is one of the source cell colors: a turn that
  /// resampled between source pixels would blend colors along cell edges, and
  /// a transparent band would show as alpha below 255.
  private static func expectEveryPixelIsACellColor(
    _ rendered: CGImage,
    sourceLocation: SourceLocation = #_sourceLocation
  ) throws {
    let pixels = try rgbaPixels(of: rendered)
    var mismatches = 0
    for offset in stride(from: 0, to: pixels.count, by: 4) {
      let isCellColor = (0..<7).contains { column in
        (0..<4).contains { row in
          let color = cellColor(column: column, row: row)
          return abs(Int(pixels[offset]) - Int(color.red)) <= 3
            && abs(Int(pixels[offset + 1]) - Int(color.green)) <= 3
            && abs(Int(pixels[offset + 2]) - Int(color.blue)) <= 3
            && pixels[offset + 3] == 255
        }
      }
      if isCellColor == false {
        mismatches += 1
      }
    }
    #expect(mismatches == 0, "\(mismatches) pixels are not a source cell color", sourceLocation: sourceLocation)
  }

  private static func rgbaPixels(of image: CGImage) throws -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress,
          width: image.width,
          height: image.height,
          bitsPerComponent: 8,
          bytesPerRow: image.width * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        )
      else {
        return false
      }
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      return true
    }
    try #require(drawn)
    return pixels
  }
}
