import CoreGraphics
import Foundation
import Testing
import UIKit

@testable import BrightroomEngine
@testable import BrightroomParametric
@testable import BrightroomUI

/// Pins which way each quarter turn rotates the picture on screen.
///
/// `QuarterTurn`'s raw value is a signed angle in the y-down (UIKit)
/// convention, while the engine evaluates crops in Core Image's y-up space, so
/// a sign is easy to name the wrong way round. These
/// tests only look at display coordinates (y-down, row 0 at the top): the
/// exported pixels, the live canvas's UIKit transform, and the rotate button.
/// A case name's direction and angle must match what the user sees.
@MainActor
struct QuarterTurnScreenDirectionTests {

  /// How a picture turns as the user sees it.
  enum ScreenTurn: Equatable, CustomStringConvertible {
    case noTurn
    case clockwise
    case halfTurn
    case counterclockwise

    /// How many corners, in clockwise order, each corner moves by.
    init?(clockwiseSteps: Int) {
      switch clockwiseSteps {
      case 0: self = .noTurn
      case 1: self = .clockwise
      case 2: self = .halfTurn
      case 3: self = .counterclockwise
      default: return nil
      }
    }

    var description: String {
      switch self {
      case .noTurn: "no turn"
      case .clockwise: "clockwise"
      case .halfTurn: "half turn"
      case .counterclockwise: "counterclockwise"
      }
    }
  }

  /// The four corners in clockwise order on screen.
  enum Corner: Int, CaseIterable {
    case topLeft
    case topRight
    case bottomRight
    case bottomLeft

    /// The pixel at this corner of a `width` × `height` image.
    func pixel(width: Int, height: Int) -> (x: Int, y: Int) {
      switch self {
      case .topLeft: (0, 0)
      case .topRight: (width - 1, 0)
      case .bottomRight: (width - 1, height - 1)
      case .bottomLeft: (0, height - 1)
      }
    }

    /// The corner as a y-down direction from the picture's center.
    var direction: CGPoint {
      switch self {
      case .topLeft: CGPoint(x: -1, y: -1)
      case .topRight: CGPoint(x: 1, y: -1)
      case .bottomRight: CGPoint(x: 1, y: 1)
      case .bottomLeft: CGPoint(x: -1, y: 1)
      }
    }
  }

  /// What each turn does on screen. The 5.x case names were `.quarterCW`
  /// (-90) and `.quarterCCW` (-270), which read the sign in y-up math and
  /// said the opposite of what the user sees.
  nonisolated static let pinned: [(QuarterTurn, ScreenTurn)] = [
    (.zero, .noTurn),
    (.counterclockwise90, .counterclockwise),
    (.counterclockwise180, .halfTurn),
    (.counterclockwise270, .clockwise),
  ]

  @Test(arguments: pinned)
  func `Export turns the picture the pinned way on screen`(
    turn: QuarterTurn,
    expected: ScreenTurn
  ) async throws {
    #expect(try await Self.exportedScreenTurn(turn) == expected)
  }

  /// The crop surface shows a turn by rotating its UIKit view, so the live
  /// canvas and the exported image must agree on the direction.
  @Test(arguments: pinned)
  func `The live canvas turns the picture the same way as export`(
    turn: QuarterTurn,
    expected: ScreenTurn
  ) {
    let crop = CropGuideState(
      imageSize: CGSize(width: 4, height: 2),
      cropRect: CGRect(x: 0, y: 0, width: 4, height: 2),
      rotation: turn
    )
    #expect(Self.screenTurn(of: CGAffineTransform(rotationAngle: crop.aggregatedRotation.radians)) == expected)
  }

  /// The built-in editor's rotate button shows the `rotate.left` symbol.
  @Test func `The rotate button turns the picture counterclockwise`() async throws {
    var rotation = QuarterTurn.zero
    var turns: [ScreenTurn?] = []
    for _ in 0..<4 {
      rotation = rotation.turnedCounterclockwise()
      turns.append(try await Self.exportedScreenTurn(rotation))
    }
    #expect(turns == [.counterclockwise, .halfTurn, .clockwise, .noTurn])
  }

  // MARK: - Measuring

  /// A 4×2 picture with a distinct color in each corner and gray elsewhere.
  private static let markers: [Corner: [UInt8]] = [
    .topLeft: [255, 0, 0],
    .topRight: [0, 255, 0],
    .bottomRight: [0, 0, 255],
    .bottomLeft: [255, 255, 0],
  ]

  private static func exportedScreenTurn(_ turn: QuarterTurn) async throws -> ScreenTurn? {
    let size = CGSize(width: 4, height: 2)
    let source = try makeFixture(width: Int(size.width), height: Int(size.height))
    let document = EditingDocument(
      source: SourceImage(cgImage: source, orientation: .up),
      feature: CropFeature(rect: CGRect(origin: .zero, size: size), quarterTurn: turn)
    )
    let rendered = try await document.render().cgImage
    let pixels = try rgbaPixels(of: rendered)

    var steps: Set<Int> = []
    for (corner, color) in markers {
      let landed = try #require(
        Corner.allCases.first { candidate in
          let (x, y) = candidate.pixel(width: rendered.width, height: rendered.height)
          let offset = (y * rendered.width + x) * 4
          return (0..<3).allSatisfy { abs(Int(pixels[offset + $0]) - Int(color[$0])) <= 2 }
        },
        "\(corner) marker is not in any output corner"
      )
      steps.insert((landed.rawValue - corner.rawValue + 4) % 4)
    }
    // A mirror would move corners by different amounts.
    guard steps.count == 1, let step = steps.first else {
      return nil
    }
    return ScreenTurn(clockwiseSteps: step)
  }

  private static func screenTurn(of transform: CGAffineTransform) -> ScreenTurn? {
    var steps: Set<Int> = []
    for corner in Corner.allCases {
      let moved = corner.direction.applying(transform)
      let rounded = CGPoint(x: moved.x.rounded(), y: moved.y.rounded())
      guard let landed = Corner.allCases.first(where: { $0.direction == rounded }) else {
        return nil
      }
      steps.insert((landed.rawValue - corner.rawValue + 4) % 4)
    }
    guard steps.count == 1, let step = steps.first else {
      return nil
    }
    return ScreenTurn(clockwiseSteps: step)
  }

  private static func makeFixture(width: Int, height: Int) throws -> CGImage {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for index in 0..<(width * height) {
      pixels[index * 4 ..< index * 4 + 4] = [128, 128, 128, 255]
    }
    for (corner, color) in markers {
      let (x, y) = corner.pixel(width: width, height: height)
      let offset = (y * width + x) * 4
      pixels[offset ..< offset + 3] = color[0..<3]
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

  /// Row 0 of the returned buffer is the top of the picture.
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
