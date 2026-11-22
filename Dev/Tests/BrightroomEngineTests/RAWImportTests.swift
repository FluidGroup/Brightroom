//
//  RAWImportTests.swift
//  BrightroomEngineTests
//
//  Created by Muukii on 2021/04/06.
//  Copyright © 2021 muukii. All rights reserved.
//

import CoreImage
import Foundation
import ImageIO
import Testing

@testable import BrightroomEngine

struct RAWImportTests {

  @Test func `import`() {

    // simulator does not work well

    let url = _url(forResource: "AppleRAW_1", ofType: "DNG")
    let data = try! Data.init(contentsOf: url)


    do {
      let filter = CIFilter(imageData: data, options: [:])!
      let image = filter.outputImage
    }
  }

  @Test func `Load orientation from URL`() {

    let url = _url(forResource: "AppleRAW_1", ofType: "DNG")

    let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
    let value = ImageDecoding.makeImageMetadata(from: source)?.orientation

    #expect(value != nil)
    #expect(value == .right)

  }

  @Test func `Load orientation from data`() {

    let url = _url(forResource: "AppleRAW_1", ofType: "DNG")
    let data = try! Data.init(contentsOf: url)

    let source = CGImageSourceCreateWithData(data as CFData, nil)!
    let value = ImageDecoding.makeImageMetadata(from: source)?.orientation

    #expect(value != nil)
    #expect(value == .right)

  }

  @Test func `A RAW image is developed once, at creation`() throws {
    let url = _url(forResource: "AppleRAW_1", ofType: "DNG")
    let fromFile = try SourceImage(rawContentsOf: url)
    let fromData = try SourceImage(rawData: Data(contentsOf: url))

    // Developed pixels are already oriented: the stored `.right` turns the
    // developed image portrait, and no orientation is left to apply.
    #expect(fromFile.storage.orientation == .up)
    #expect(fromFile.pixelSize == fromData.pixelSize)
    #expect(fromFile.pixelSize.height > fromFile.pixelSize.width)
    guard case .bitmap(let bitmap) = fromFile.storage.backing,
      case .bitmap(let dataBitmap) = fromData.storage.backing
    else {
      Issue.record("A RAW image keeps its developed bitmap.")
      return
    }
    for developed in [bitmap, dataBitmap] {
      #expect(developed.bitsPerComponent == 16)
      #expect(developed.bitmapInfo.contains(.floatComponents))
      #expect(developed.colorSpace?.name == CGColorSpace.extendedLinearDisplayP3)
    }
    #expect(fromFile.makeCIImage().extent == CGRect(origin: .zero, size: fromFile.pixelSize))
  }

  @Test func `Developed RAW precision survives the editing preview`() throws {
    let source = try SourceImage(rawContentsOf: _url(forResource: "AppleRAW_1", ofType: "DNG"))
    let preview = try #require(source.storage.makeResizedCGImage(shortSideLength: 320))
    #expect(preview.bitsPerComponent == 16)
    #expect(preview.bitmapInfo.contains(.floatComponents))
    #expect(preview.colorSpace?.name == CGColorSpace.extendedLinearDisplayP3)

    let uploaded = try #require(PreviewTextureUpload.makeGPUResidentSource(cgImage: preview, orientation: .up))
    let space = try #require(CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
    let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf])
    func read(_ image: CIImage) -> [Float] {
      var pixels = [Float](repeating: .nan, count: preview.width * preview.height * 4)
      context.render(image, toBitmap: &pixels, rowBytes: preview.width * 16,
        bounds: image.extent, format: .RGBAf, colorSpace: space)
      return pixels
    }
    let expected = read(CIImage(cgImage: preview))
    let actual = read(uploaded)
    #expect(actual.allSatisfy { $0.isFinite })
    #expect(zip(actual, expected).allSatisfy { abs($0 - $1) < 0.001 })
    // The GPU preview must contain more than the 256 levels an 8-bit upload
    // could retain. Count one channel of the actual rendered photograph.
    #expect(Set(stride(from: 0, to: actual.count, by: 4).map { actual[$0] }).count > 256)
  }
}
