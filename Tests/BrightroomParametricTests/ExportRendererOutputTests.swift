//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import BrightroomParametric

/// Pins the result and error shape of `ExportRenderer`: sharing data is
/// encoded in the requested `FileType`, and every export failure is an
/// `ExportRendererError` a caller can match with `==`.
struct ExportRendererOutputTests {

  private typealias Fixtures = RenderingFixtures

  @Test(arguments: [
    (ExportRenderer.FileType.jpeg(quality: 0.9), UTType.jpeg),
    (ExportRenderer.FileType.heif(quality: 0.9), UTType.heic),
    (ExportRenderer.FileType.png, UTType.png),
  ])
  func `sharing data is encoded in the requested file type`(
    fileType: ExportRenderer.FileType,
    expectedType: UTType
  ) throws {
    let rendered = try ExportRenderer().render(
      from: try Fixtures.makeSource(),
      feature: EmptyFeature()
    )

    let data = try rendered.sharingData(as: fileType)

    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let type = try #require(CGImageSourceGetType(source) as String?)
    #expect(UTType(type)?.conforms(to: expectedType) == true)
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let expected = try rendered.cgImage
    #expect(image.width == expected.width)
    #expect(image.height == expected.height)
  }

  @Test func `a file write failure is a matchable ExportRendererError`() throws {
    // An infinite source has no finite extent to write.
    let infinite = CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 1))
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("export-renderer-output-tests-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: url) }

    let error = #expect(throws: ExportRendererError.self) {
      try ExportRenderer().render(
        from: infinite,
        feature: EmptyFeature(),
        options: .init(output: .file(url: url, fileType: .png))
      )
    }

    #expect(error == .fileWriteFailed(url, step: .validatingExtent))
    #expect(error?.errorDescription?.contains("validating the image extent") == true)
  }

  @Test func `a missing rendered file is a matchable ExportRendererError`() throws {
    let rendered = try ExportRenderer().render(
      from: try Fixtures.makeSource(),
      feature: EmptyFeature()
    )
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("export-renderer-output-tests-\(UUID().uuidString).png")
    let missing = RenderedImage(fileURL: url, options: rendered.options)

    let error = #expect(throws: ExportRendererError.self) {
      _ = try missing.cgImage
    }

    #expect(error == .failedToDecodeRenderedFile(url))
  }
}
