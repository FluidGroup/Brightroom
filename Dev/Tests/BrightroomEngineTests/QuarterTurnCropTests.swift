import CoreGraphics
import CoreImage
import Testing
import UIKit

@testable import BrightroomEngine
@testable import BrightroomParametric
@testable import BrightroomUI

/// Verifies source pixels, crop geometry, and model round trips independently
/// of the engine's rotation transform and pixel snapper.
@MainActor
struct QuarterTurnCropTests {

  private let imageSize = CGSize(width: 300, height: 200)

  // MARK: - Quarter turns without resampling

  @Test(
    arguments: [
      CGSize(width: 6, height: 4),
      CGSize(width: 7, height: 4),
      CGSize(width: 4, height: 7),
      CGSize(width: 7, height: 5),
      CGSize(width: 1, height: 2),
      CGSize(width: 301, height: 200),
    ],
    QuarterTurn.allCases
  )
  func `Turning the full image preserves every source pixel`(
    size: CGSize,
    rotation: QuarterTurn
  ) async throws {
    let source = try Self.makePixelImage(size: size)
    let stack = makeStack(source: source)
    let initial = try #require(stack.featureTree?.finalCrop)
    let sourceRect = CGRect(origin: .zero, size: size)
    let expectedExtent = sourceRect

    var crop = CropEditingState(cropFeature: initial, imageSize: size)
    crop.updateCropExtent(expectedExtent)
    crop.rotation = CropRotation(rotation)

    let committed = try commit(crop, to: stack)
    #expect(committed.displayCropRect(imageSize: size) == expectedExtent)
    #expect(committed.rotation == rotation)

    let rendered = try await stack.makeRenderer().render().cgImage
    try Self.expectPixels(rendered, from: source, sourceRect: sourceRect, rotation: rotation)

    // Output orientation changes neither the selected source rectangle nor
    // the source rows and columns preserved when the model is reopened.
    let reseeded = CropEditingState(cropFeature: committed, imageSize: size)
    #expect(reseeded.cropExtent == expectedExtent)
    #expect(reseeded.makeCropFeature().cropRect == committed.cropRect)
    #expect(reseeded.makeCropFeature().rotation == committed.rotation)
  }

  @Test(
    arguments: [
      CGRect(x: 2, y: 1, width: 5, height: 4),
      CGRect(x: 1, y: 2, width: 6, height: 4),
    ],
    QuarterTurn.allCases
  )
  func `Turning an off-center partial crop preserves its source pixels`(
    sourceRect: CGRect,
    rotation: QuarterTurn
  ) async throws {
    let size = CGSize(width: 9, height: 8)
    let source = try Self.makePixelImage(size: size)
    let stack = makeStack(source: source)
    let initial = try #require(stack.featureTree?.finalCrop)
    let expectedExtent = sourceRect

    var crop = CropEditingState(cropFeature: initial, imageSize: size)
    crop.updateCropExtent(expectedExtent)
    crop.rotation = CropRotation(rotation)

    let committed = try commit(crop, to: stack)
    #expect(committed.displayCropRect(imageSize: size) == expectedExtent)
    let rendered = try await stack.makeRenderer().render().cgImage
    try Self.expectPixels(rendered, from: source, sourceRect: sourceRect, rotation: rotation)

    let reopened = CropEditingState(cropFeature: committed, imageSize: size)
    #expect(reopened.cropExtent == expectedExtent)
    #expect(reopened.makeCropFeature().cropRect == committed.cropRect)
  }

  /// Rotation leaves the selected rectangle unchanged, and Done commits that
  /// same rectangle with the newly selected output orientation.
  @Test(arguments: [300.0, 301.0])
  func `Rotation button and Done preserve the full source through four turns`(imageWidth: Double) throws {
    let size = CGSize(width: imageWidth, height: 200)
    let stack = try makeStack(size: size)
    let (editor, window) = openCropView(on: stack)
    var latestCrop: CropEditingState?
    editor.setStateHandler { latestCrop = $0.proposedCrop }

    for rotation in [QuarterTurn.quarterCW, .half, .quarterCCW, .zero] {
      editor.rotateClockwise()
      editor.layoutIfNeeded()
      let crop = try #require(latestCrop)
      let expectedExtent = CGRect(origin: .zero, size: size)
      #expect(crop.rotation.quarterTurn == rotation)
      #expect(crop.cropExtent == expectedExtent)
      #expect(crop.outputCropExtent == Self.outputFrame(for: expectedExtent, rotation: rotation))
      let proposed = crop.makeCropFeature()
      #expect(proposed.displayCropRect(imageSize: size) == expectedExtent)

      editor.applyDocumentChanges()
      let committed = try #require(stack.featureTree?.finalCrop)
      #expect(committed.cropRect == proposed.cropRect)
      #expect(committed.rotation == rotation)
      #expect(committed.straightenRadians == proposed.straightenRadians)
    }
    withExtendedLifetime(window) {}
  }

  // MARK: - Open and Done without edits

  /// Starts with an exact persisted crop. Opening the view and pressing Done
  /// preserves that crop without measuring a replacement frame from UIKit.
  @Test(arguments: [301.0, 300.0], [QuarterTurn.quarterCW, .quarterCCW])
  func `Open and Done keeps a turned full-image crop`(
    imageWidth: Double,
    rotation: QuarterTurn
  ) throws {
    let size = CGSize(width: imageWidth, height: 200)
    let stack = try makeStack(size: size)
    let initial = try #require(stack.featureTree?.finalCrop)
    let expectedExtent = CGRect(origin: .zero, size: size)
    var crop = CropEditingState(cropFeature: initial, imageSize: size)
    crop.updateCropExtent(expectedExtent)
    crop.rotation = CropRotation(rotation)
    let committed = try commit(crop, to: stack)
    #expect(committed.displayCropRect(imageSize: size) == expectedExtent)

    for cycle in 1...4 {
      let (editor, window) = openCropView(on: stack)
      editor.applyDocumentChanges()
      let recorded = try #require(stack.featureTree?.finalCrop)
      #expect(recorded.id == committed.id)
      #expect(recorded.rotation == rotation)
      #expect(recorded.cropRect == committed.cropRect, "after open and Done #\(cycle)")
      window.isHidden = true
      withExtendedLifetime(window) {}
    }
  }

  /// Preserving proposed state also applies to offset selections with a free
  /// straighten angle, where measuring the viewport could change both axes.
  @Test(arguments: [(QuarterTurn.quarterCW, -11.0), (.quarterCCW, 7.0)])
  func `Open and Done keeps a straightened partial crop`(
    rotation: QuarterTurn,
    straightenDegrees: Double
  ) throws {
    let size = CGSize(width: 53, height: 40)
    let stack = try makeStack(size: size)
    let initial = try #require(stack.featureTree?.finalCrop)
    let expectedExtent = CGRect(x: 10, y: 8, width: 29, height: 20)
    var crop = CropEditingState(cropFeature: initial, imageSize: size)
    crop.updateCropExtent(expectedExtent)
    crop.rotation = CropRotation(rotation)
    crop.adjustmentAngle = .degrees(straightenDegrees)
    let committed = try commit(crop, to: stack)
    #expect(committed.displayCropRect(imageSize: size) == expectedExtent)

    for cycle in 1...3 {
      let (editor, window) = openCropView(on: stack)
      editor.applyDocumentChanges()
      let recorded = try #require(stack.featureTree?.finalCrop)
      #expect(recorded.id == committed.id)
      #expect(recorded.rotation == committed.rotation)
      #expect(recorded.straightenRadians == committed.straightenRadians)
      #expect(recorded.cropRect == committed.cropRect, "after open and Done #\(cycle)")
      window.isHidden = true
      withExtendedLifetime(window) {}
    }
  }

  // MARK: - Quarter turn + straighten

  /// Rotating an already straightened crop is a pixel permutation of its
  /// unturned output, including mixed-parity dimensions and an offset center.
  @Test(arguments: [-11.0, 7.0], [QuarterTurn.quarterCW, .half, .quarterCCW])
  func `Quarter turn rotates the same straightened crop`(
    straightenDegrees: Double,
    rotation: QuarterTurn
  ) async throws {
    let size = CGSize(width: 53, height: 40)
    let source = try Self.makePixelImage(size: size)
    let sourceRect = CGRect(x: 10, y: 8, width: 29, height: 20)
    let straighten = straightenDegrees * .pi / 180
    let baselineCrop = CropFeature(
      displayCropRect: sourceRect,
      imageSize: size,
      straighten: straighten
    )
    let baseline = try await Self.render(source, crop: baselineCrop)
    let expectedExtent = sourceRect
    let turnedCrop = CropFeature(
      displayCropRect: expectedExtent,
      imageSize: size,
      rotation: rotation,
      straighten: straighten
    )
    #expect(turnedCrop.displayCropRect(imageSize: size) == expectedExtent)

    let rendered = try await Self.render(source, crop: turnedCrop)
    try Self.expectPixels(
      rendered,
      from: baseline,
      sourceRect: CGRect(origin: .zero, size: sourceRect.size),
      rotation: rotation
    )

    let reopened = CropEditingState(cropFeature: turnedCrop, imageSize: size)
    #expect(reopened.cropExtent == expectedExtent)
    #expect(reopened.makeCropFeature().cropRect == turnedCrop.cropRect)
    #expect(reopened.makeCropFeature().straightenRadians == straighten)
  }

  @Test(arguments: [(301.0, 2.0), (300.0, 5.0)])
  func `A straightened quarter turn exports no transparent pixels`(
    imageWidth: Double,
    straightenDegrees: Double
  ) async throws {
    let size = CGSize(width: imageWidth, height: 200)
    let stack = try makeStack(size: size)

    let (editor, window) = openCropView(on: stack)
    editor.rotateClockwise()
    editor.layoutIfNeeded()
    editor.setAdjustmentAngle(.degrees(straightenDegrees))
    editor.layoutIfNeeded()
    editor.applyDocumentChanges()
    withExtendedLifetime(window) {}

    let rendered = try await stack.makeRenderer().render().cgImage
    let pixels = try Self.rgbaPixels(of: rendered)
    let notOpaque = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] < 255 }
    #expect(
      notOpaque.isEmpty,
      "\(notOpaque.count) pixels, min alpha \(notOpaque.map { pixels[$0] }.min() ?? 255)"
    )
  }

  /// Its 36×210 pre-turn frame extends beyond the source, but straightening
  /// rotates the sampled area fully inside the 300×200 image. A quarter-turn
  /// bounding-box clamp would incorrectly cut ten pixels from the long side.
  @Test func `A straightened thin turned crop keeps its frame`() {
    let extent = CGRect(x: 132, y: -5, width: 36, height: 210)
    let feature = CropFeature(
      displayCropRect: extent,
      imageSize: imageSize,
      rotation: .quarterCW,
      straighten: 30 * .pi / 180
    )

    #expect(feature.displayCropRect(imageSize: imageSize) == extent)
    let reopened = CropEditingState(cropFeature: feature, imageSize: imageSize)
    #expect(reopened.cropExtent == extent)
    #expect(reopened.makeCropFeature().cropRect == feature.cropRect)
  }

  // MARK: - Bounds and aspect ratio

  @Test(arguments: QuarterTurn.allCases)
  func `Crop selection clamps identically for every output rotation`(rotation: QuarterTurn) {
    let cases: [(requested: CGRect, expected: CGRect)] = [
      (CGRect(x: 50, y: -60, width: 240, height: 120), CGRect(x: 50, y: 0, width: 240, height: 60)),
      (CGRect(x: -40, y: 0, width: 60, height: 10), CGRect(x: 0, y: 0, width: 20, height: 10)),
      (CGRect(x: 50, y: -50, width: 200, height: 300), CGRect(x: 50, y: 0, width: 200, height: 200)),
    ]

    for fixture in cases {
      let feature = CropFeature(
        displayCropRect: fixture.requested,
        imageSize: imageSize,
        rotation: rotation
      )
      #expect(feature.displayCropRect(imageSize: imageSize) == fixture.expected)

      // A raw stored crop is normalized the same way when its editor opens.
      let stored = CropFeature(
        cropRect: CGRect(
          x: fixture.requested.minX,
          y: imageSize.height - fixture.requested.maxY,
          width: fixture.requested.width,
          height: fixture.requested.height
        ),
        rotation: rotation
      )
      let reopened = CropEditingState(cropFeature: stored, imageSize: imageSize)
      #expect(reopened.cropExtent == fixture.expected)
      #expect(reopened.makeCropFeature().displayCropRect(imageSize: imageSize) == fixture.expected)
    }
  }

  /// A locked ratio rotates with a partial selection. It must not refit the
  /// selection to the maximum rectangle of that ratio in the source image.
  @Test func `Four rotation button presses preserve a partial crop and its aspect lock`() throws {
    let stack = try makeStack(size: imageSize)
    let (editor, window) = openCropView(on: stack)
    var latest: CropView.StateSnapshot?
    editor.setStateHandler { latest = $0 }
    let sourceRatio = PixelAspectRatio(width: 3, height: 2)
    editor.setCroppingAspectRatio(sourceRatio)

    let sourceRect = CGRect(x: 50, y: 40, width: 153, height: 102)
    var crop = try #require(latest?.proposedCrop)
    crop.updateCropExtent(sourceRect)
    editor.setCrop(crop)
    editor.layoutIfNeeded()
    let selected = try #require(latest?.proposedCrop)
    #expect(selected.cropExtent == sourceRect)

    for rotation in [QuarterTurn.quarterCW, .half, .quarterCCW, .zero] {
      editor.rotateClockwise()
      editor.layoutIfNeeded()
      let snapshot = try #require(latest)
      let rotated = try #require(snapshot.proposedCrop)
      let isSideways = rotation == .quarterCW || rotation == .quarterCCW
      let expectedRatio = isSideways ? sourceRatio.swapped() : sourceRatio
      let expectedExtent = sourceRect
      #expect(snapshot.preferredAspectRatio == expectedRatio)
      #expect(rotated._usedAspectRatio == expectedRatio)
      #expect(rotated.rotation.quarterTurn == rotation)
      #expect(rotated.cropExtent == expectedExtent)
      #expect(rotated.outputCropExtent == Self.outputFrame(for: sourceRect, rotation: rotation))
      #expect(rotated.makeCropFeature().displayCropRect(imageSize: imageSize) == expectedExtent)
    }
    withExtendedLifetime(window) {}
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

  /// Opens a CropView on the stack's current crop, laid out in a window the
  /// caller keeps alive.
  private func openCropView(on stack: EditingStack) -> (CropView, UIWindow) {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
    let view = CropView(document: CropViewDocument(editingStack: stack))
    view.areAnimationsEnabled = false
    view.frame = window.bounds
    window.addSubview(view)
    window.isHidden = false
    view.layoutIfNeeded()
    view.loadCurrentDocumentState()
    view.layoutIfNeeded()
    return (view, window)
  }

  /// The viewport frame has the source crop's center and the turned size.
  /// This expectation uses no engine geometry helpers or trigonometry.
  private static func outputFrame(for sourceRect: CGRect, rotation: QuarterTurn) -> CGRect {
    switch rotation {
    case .zero, .half:
      return sourceRect
    case .quarterCW, .quarterCCW:
      return CGRect(
        x: sourceRect.midX - sourceRect.height / 2,
        y: sourceRect.midY - sourceRect.width / 2,
        width: sourceRect.height,
        height: sourceRect.width
      )
    }
  }

  private func makeStack(size: CGSize) throws -> EditingStack {
    makeStack(source: try Self.makePixelImage(size: size))
  }

  private func makeStack(source: CGImage) -> EditingStack {
    let size = CGSize(width: source.width, height: source.height)
    let sourceCIImage = CIImage(cgImage: source)
    let initialEdit = EditingStack.Edit.test(imageSize: size)
    let loaded = EditingStack.Loaded(
      imageSource: ImageSource(cgImage: source),
      metadata: .init(orientation: .up, imageSize: size),
      initialEditing: initialEdit,
      currentEdit: initialEdit,
      thumbnailCIImage: sourceCIImage,
      editingSourceCGImage: source,
      editingSourceCIImage: sourceCIImage
    )
    let stack = EditingStack(imageProvider: .init(image: UIImage(cgImage: source)))
    stack.loadedState = loaded
    return stack
  }

  private static func render(_ source: CGImage, crop: CropFeature) async throws -> CGImage {
    let renderer = BrightRoomImageRenderer(source: ImageSource(cgImage: source), orientation: .up)
    renderer.edit = .make(
      crop: crop,
      orientedImageSize: CGSize(width: source.width, height: source.height)
    )
    return try await renderer.render().cgImage
  }

  /// Gives every pixel a distinct, sharply changing color. A one-pixel shift
  /// cannot hide inside a large uniform cell or a smooth gradient.
  private static func makePixelImage(size: CGSize) throws -> CGImage {
    let width = Int(size.width)
    let height = Int(size.height)
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for index in 0..<(width * height) {
      // Multiplication by an odd value permutes the 24-bit color space.
      let color = (index * 0x9E3779) & 0xFFFFFF
      pixels[index * 4] = UInt8((color >> 16) & 255)
      pixels[index * 4 + 1] = UInt8((color >> 8) & 255)
      pixels[index * 4 + 2] = UInt8(color & 255)
    }
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    return try #require(CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue
        | CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    ))
  }

  /// Compares every output pixel with an integer-index permutation of the
  /// selected source rectangle. The established rotation sign is expressed
  /// explicitly here, independently of the rendering affine transform.
  private static func expectPixels(
    _ rendered: CGImage,
    from source: CGImage,
    sourceRect: CGRect,
    rotation: QuarterTurn,
    sourceLocation: SourceLocation = #_sourceLocation
  ) throws {
    let width = Int(sourceRect.width)
    let height = Int(sourceRect.height)
    let isSideways = rotation == .quarterCW || rotation == .quarterCCW
    let outputWidth = isSideways ? height : width
    let outputHeight = isSideways ? width : height
    try #require(rendered.width == outputWidth, sourceLocation: sourceLocation)
    try #require(rendered.height == outputHeight, sourceLocation: sourceLocation)
    let actual = try rgbaPixels(of: rendered)
    let expected = try rgbaPixels(of: source)
    var mismatches = 0
    var firstMismatch: String?

    for y in 0..<outputHeight {
      for x in 0..<outputWidth {
        let sourceX: Int
        let sourceY: Int
        switch rotation {
        case .zero:
          (sourceX, sourceY) = (x, y)
        case .quarterCW:
          (sourceX, sourceY) = (width - 1 - y, x)
        case .half:
          (sourceX, sourceY) = (width - 1 - x, height - 1 - y)
        case .quarterCCW:
          (sourceX, sourceY) = (y, height - 1 - x)
        }
        let actualOffset = (y * outputWidth + x) * 4
        let expectedOffset = (
          (Int(sourceRect.minY) + sourceY) * source.width + Int(sourceRect.minX) + sourceX
        ) * 4
        // One code value permits color-space conversion rounding; the fixture's
        // adjacent source pixels differ enough to expose any displaced sample.
        let rgbMatches = (0..<3).allSatisfy {
          abs(Int(actual[actualOffset + $0]) - Int(expected[expectedOffset + $0])) <= 1
        }
        if !rgbMatches || actual[actualOffset + 3] != expected[expectedOffset + 3] {
          mismatches += 1
          if firstMismatch == nil {
            firstMismatch = "output (\(x), \(y)), source (\(sourceX), \(sourceY)): "
              + "\(Array(actual[actualOffset..<(actualOffset + 4)])) != "
              + "\(Array(expected[expectedOffset..<(expectedOffset + 4)]))"
          }
        }
      }
    }
    #expect(
      mismatches == 0,
      "\(mismatches) pixel mismatches; \(firstMismatch ?? "none")",
      sourceLocation: sourceLocation
    )
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
