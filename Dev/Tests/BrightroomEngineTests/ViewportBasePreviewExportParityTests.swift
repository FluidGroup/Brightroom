import CoreImage
import Foundation
import Metal
import os
import Testing
import UIKit

@testable import BrightroomEngine
@testable import BrightroomParametric
@testable import BrightroomUI

/// Pins the canvas `.viewportBase` path to the export's evaluation order.
///
/// `ImageEditorFeature` evaluates its effects before the final crop, so an
/// effect that reads its input extent (a vignette) or its neighbours at the
/// crop edge (a sharpen) sees the whole source. The canvas shows the global
/// effects without a local adjustment through `.viewportBase`; it must
/// evaluate them in the same order, on the downsampled editing source, as the
/// `.localAdjustment` base does. Otherwise the Adjust preview differs from the
/// export, and drawing the first stroke (which switches to
/// `.localAdjustment`) changes pixels far from the stroke.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct ViewportBasePreviewExportParityTests {

  private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
  private static let imageSize = CGSize(width: 120, height: 80)
  /// An off-centre selection, so the source centre is outside the crop
  /// output's centre and the crop edges cut through texture.
  private static let cropRect = CGRect(x: 8, y: 12, width: 64, height: 48)

  // MARK: - Tool surface without strokes matches export

  @Test(arguments: [QuarterTurn.zero, .counterclockwise90])
  func `Tool surface without strokes matches export through an off-centre crop`(
    quarterTurn: QuarterTurn
  ) async throws {
    let source = Self.makeTexturedImage()
    let document = Self.makeDocument(quarterTurn: quarterTurn)
    #expect(EditingCanvasView.CanvasRenderPlan(localBlur: document.localBlur) == .viewportBase)

    let exported = try await EditingDocument(
      source: SourceImage(cgImage: source),
      feature: document
    ).render(options: .init(outputColorSpace: Self.sRGB)).cgImage
    let preview = try CanvasCompositionPreview.render(
      document: document,
      source: source,
      throughCrop: true
    )

    #expect(exported.width == preview.width)
    #expect(exported.height == preview.height)
    let difference = Self.maximumDifference(exported, preview)
    #expect(difference.value <= 2, "preview differs from export by \(difference.value) at \(difference.point)")
  }

  // MARK: - The first stroke keeps the base

  @Test func `The first stroke does not change pixels away from it`() throws {
    let source = Self.makeTexturedImage()
    var unstroked = Self.makeDocument(quarterTurn: .zero)
    unstroked.localBlur = nil

    // One stamp in the source domain (y-down); in the crop output it sits at
    // (strokeCenter - cropRect.origin).
    let strokeCenter = CGPoint(x: 30, y: 30)
    let strokeDiameter = 10.0
    var stroked = unstroked
    stroked.localBlur = LocalAdjustmentFeature(
      mask: .test(
        displayStamps: [strokeCenter],
        diameter: strokeDiameter,
        domainHeight: Self.imageSize.height
      )
    ) {
      GaussianBlurFeature(radius: .absolute(4))
    }
    #expect(EditingCanvasView.CanvasRenderPlan(localBlur: unstroked.localBlur) == .viewportBase)
    #expect(EditingCanvasView.CanvasRenderPlan(localBlur: stroked.localBlur) != .viewportBase)

    let before = try CanvasCompositionPreview.render(document: unstroked, source: source, throughCrop: true)
    let after = try CanvasCompositionPreview.render(document: stroked, source: source, throughCrop: true)
    #expect(before.width == after.width)
    #expect(before.height == after.height)

    let strokeInOutput = CGPoint(
      x: strokeCenter.x - Self.cropRect.minX,
      y: strokeCenter.y - Self.cropRect.minY
    )
    let reach = strokeDiameter / 2 + 4 * 3 + 2
    let before8 = Self.pixels(before)
    let after8 = Self.pixels(after)
    var largestAway = 0
    var largestAwayPoint = (0, 0)
    for y in 0..<before.height {
      for x in 0..<before.width {
        let distance = hypot(CGFloat(x) + 0.5 - strokeInOutput.x, CGFloat(y) + 0.5 - strokeInOutput.y)
        guard distance > reach else { continue }
        let d = Self.difference(before8, after8, width: before.width, x: x, y: y)
        if d > largestAway {
          largestAway = d
          largestAwayPoint = (x, y)
        }
      }
    }
    #expect(largestAway <= 1, "the first stroke changed \(largestAwayPoint) by \(largestAway)")

    // The stroke itself is visible, so the two renders took different paths.
    let atStroke = Self.difference(
      before8,
      after8,
      width: before.width,
      x: Int(strokeInOutput.x),
      y: Int(strokeInOutput.y)
    )
    #expect(atStroke > 10)
  }

  // MARK: - Effects run on the editing source

  /// A 12000² source shown through a 256² editing source: the global effects
  /// of the `.viewportBase` path receive the editing source, with its extent
  /// as the chain entry, not a 12000² upscale (or its crop).
  @Test func `Viewport base effects evaluate on the editing source`() throws {
    let editingSource = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
      .cropped(to: CGRect(x: 0, y: 0, width: 256, height: 256))
    let sourceSize = CGSize(width: 12000, height: 12000)
    let editingExtent = CGRect(x: 0, y: 0, width: 256, height: 256)

    let cropSurfaceRecorder = ExtentRecorder()
    _ = try #require(
      EditingCanvasRenderImageFactory.makeRenderImages(
        editingSourceImage: editingSource,
        effects: AnyImageEffect(ExtentRecordingEffect(recorder: cropSurfaceRecorder)),
        canvasSize: sourceSize,
        mode: .viewportBase
      )
    )
    #expect(cropSurfaceRecorder.records == [.init(input: editingExtent, chainEntry: editingExtent)])

    let toolSurfaceRecorder = ExtentRecorder()
    let geometry = try #require(
      EditingCanvasCropOutputGeometry(
        crop: CropGuideState(
          cropFeature: CropFeature.test(
            imageSize: sourceSize,
            topLeftRect: CGRect(x: 1000, y: 2000, width: 6000, height: 4000)
          ),
          imageSize: sourceSize
        )
      )
    )
    _ = try #require(
      EditingCanvasRenderImageFactory.makeCropOutputRenderImages(
        editingSourceImage: editingSource,
        effects: AnyImageEffect(ExtentRecordingEffect(recorder: toolSurfaceRecorder)),
        geometry: geometry,
        mode: .viewportBase
      )
    )
    #expect(toolSurfaceRecorder.records == [.init(input: editingExtent, chainEntry: editingExtent)])
  }

  // MARK: - Fixtures

  private static func makeDocument(quarterTurn: QuarterTurn) -> ImageEditorFeature {
    var document = ImageEditorFeature(imageSize: imageSize)
    document.effects.sharpen = SharpenFeature(intensity: 0.8, radius: .proportional(20))
    document.effects.vignette = VignetteFeature(value: 1)
    document.crop = CropFeature.test(
      imageSize: imageSize,
      topLeftRect: cropRect,
      quarterTurn: quarterTurn
    )
    return document
  }

  /// A horizontal ramp with a checker over its top half: texture for the
  /// sharpen at the crop edges, asymmetric in both axes.
  private static func makeTexturedImage() -> CGImage {
    let width = Int(imageSize.width)
    let height = Int(imageSize.height)
    let cell = 3
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    return UIGraphicsImageRenderer(size: imageSize, format: format).image { _ in
      for x in 0..<width {
        UIColor(white: 0.25 + 0.5 * CGFloat(x) / CGFloat(width), alpha: 1).setFill()
        UIRectFill(CGRect(x: x, y: 0, width: 1, height: height))
      }
      UIColor(white: 0.9, alpha: 1).setFill()
      for y in stride(from: 0, to: height / 2, by: cell) {
        for x in stride(from: 0, to: width, by: cell) where (x / cell + y / cell).isMultiple(of: 2) {
          UIRectFill(CGRect(x: x, y: y, width: cell, height: cell))
        }
      }
    }.cgImage!
  }

  // MARK: - Pixels

  private static func pixels(_ image: CGImage) -> [UInt8] {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(
      data: &pixels,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: sRGB,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return pixels
  }

  /// The largest channel difference (RGBA) at one top-left-origin pixel.
  private static func difference(_ lhs: [UInt8], _ rhs: [UInt8], width: Int, x: Int, y: Int) -> Int {
    let offset = (y * width + x) * 4
    return (0..<4).map { abs(Int(lhs[offset + $0]) - Int(rhs[offset + $0])) }.max() ?? 0
  }

  private static func maximumDifference(_ lhs: CGImage, _ rhs: CGImage) -> (value: Int, point: (Int, Int)) {
    guard lhs.width == rhs.width, lhs.height == rhs.height else {
      return (255, (0, 0))
    }
    let a = pixels(lhs)
    let b = pixels(rhs)
    var largest = 0
    var point = (0, 0)
    for y in 0..<lhs.height {
      for x in 0..<lhs.width {
        let d = difference(a, b, width: lhs.width, x: x, y: y)
        if d > largest {
          largest = d
          point = (x, y)
        }
      }
    }
    return (largest, point)
  }
}

/// Records the extents an effect is evaluated with.
private final class ExtentRecorder: Sendable {

  struct Record: Equatable {
    var input: CGRect
    var chainEntry: CGRect
  }

  private let storage = OSAllocatedUnfairLock<[Record]>(initialState: [])

  var records: [Record] {
    storage.withLock { $0 }
  }

  func append(_ record: Record) {
    storage.withLock { $0.append(record) }
  }
}

/// An identity effect that records its input extent and chain-entry extent.
private struct ExtentRecordingEffect: ImageEffect, Equatable {

  let recorder: ExtentRecorder

  func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    recorder.append(.init(input: image.extent, chainEntry: context.chainEntryExtent(for: image)))
    return image
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.recorder === rhs.recorder
  }
}
