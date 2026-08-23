//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import Darwin
import Foundation

/// The internal representation produced while parsing a `.cube` text file.
struct _ParsedColorCube {
  let title: String?
  let dimension: Int
  let cubeData: Data
}

/// A trimmed, comment-free line in a color-cube text source.
private struct _ColorCubeTextLine {
  let range: Range<Int>
  let number: Int
}

/// Provides allocation-free token and numeric access to one UTF-8 source.
///
/// The source is valid only while the parser's UTF-8 storage is borrowed.
private struct _ColorCubeUTF8Source {

  let bytes: UnsafeBufferPointer<UInt8>

  func nextToken(
    in line: _ColorCubeTextLine,
    cursor: inout Int
  ) -> Range<Int>? {
    while cursor < line.range.upperBound, Self.isWhitespace(bytes[cursor]) {
      cursor += 1
    }
    guard cursor < line.range.upperBound else {
      return nil
    }

    let start = cursor
    while cursor < line.range.upperBound, Self.isWhitespace(bytes[cursor]) == false {
      cursor += 1
    }
    return start..<cursor
  }

  func string(in range: Range<Int>) -> String {
    guard let baseAddress = bytes.baseAddress else {
      return ""
    }
    return String(
      decoding: UnsafeBufferPointer(
        start: baseAddress.advanced(by: range.lowerBound),
        count: range.count
      ),
      as: UTF8.self
    )
  }

  func token(
    in range: Range<Int>,
    equalsASCII keyword: StaticString
  ) -> Bool {
    keyword.withUTF8Buffer { keywordBytes in
      guard range.count == keywordBytes.count else {
        return false
      }
      for offset in keywordBytes.indices {
        guard
          Self.uppercasedASCII(bytes[range.lowerBound + offset])
            == Self.uppercasedASCII(keywordBytes[offset])
        else {
          return false
        }
      }
      return true
    }
  }

  /// Parses one complete token while borrowing the source's trailing NUL byte.
  func float(in range: Range<Int>) -> Float? {
    guard let baseAddress = bytes.baseAddress else {
      return nil
    }

    let tokenStart = UnsafeRawPointer(
      baseAddress.advanced(by: range.lowerBound)
    ).assumingMemoryBound(to: CChar.self)
    var parsedEnd: UnsafeMutablePointer<CChar>?
    let value = strtof(tokenStart, &parsedEnd)
    let expectedEnd = UnsafeMutablePointer(mutating: tokenStart)
      .advanced(by: range.count)
    guard parsedEnd == expectedEnd else {
      return nil
    }
    return value
  }

  static func isWhitespace(_ byte: UInt8) -> Bool {
    switch byte {
    case 0x09, 0x0B, 0x0C, 0x0D, 0x20:
      return true
    default:
      return false
    }
  }

  private static func uppercasedASCII(_ byte: UInt8) -> UInt8 {
    guard byte >= 0x61, byte <= 0x7A else {
      return byte
    }
    return byte - 0x20
  }
}

/// Iterates logical lines without first splitting the complete source string.
private struct _ColorCubeTextLineIterator: IteratorProtocol {

  private let source: _ColorCubeUTF8Source
  private var cursor = 0
  private var lineNumber = 0

  init(source: _ColorCubeUTF8Source) {
    self.source = source
  }

  mutating func next() -> _ColorCubeTextLine? {
    while cursor < source.bytes.count {
      lineNumber += 1
      let lineStart = cursor
      while
        cursor < source.bytes.count,
        source.bytes[cursor] != 0x0A,
        source.bytes[cursor] != 0x0D
      {
        cursor += 1
      }
      let lineEnd = cursor

      if cursor < source.bytes.count {
        let newline = source.bytes[cursor]
        cursor += 1
        if
          newline == 0x0D,
          cursor < source.bytes.count,
          source.bytes[cursor] == 0x0A
        {
          cursor += 1
        }
      }

      var contentEnd = lineStart
      while contentEnd < lineEnd, source.bytes[contentEnd] != 0x23 {
        contentEnd += 1
      }

      var trimmedStart = lineStart
      while
        trimmedStart < contentEnd,
        _ColorCubeUTF8Source.isWhitespace(source.bytes[trimmedStart])
      {
        trimmedStart += 1
      }

      var trimmedEnd = contentEnd
      while
        trimmedEnd > trimmedStart,
        _ColorCubeUTF8Source.isWhitespace(source.bytes[trimmedEnd - 1])
      {
        trimmedEnd -= 1
      }

      guard trimmedStart < trimmedEnd else {
        continue
      }
      return _ColorCubeTextLine(
        range: trimmedStart..<trimmedEnd,
        number: lineNumber
      )
    }
    return nil
  }
}

/// Parses three-dimensional `.cube` text without exposing parser mechanics as
/// part of BrightroomParametric's public surface.
struct _ColorCubeTextParser {

  func parse(contentsOf url: URL) throws -> _ParsedColorCube {
    try parse(String(contentsOf: url, encoding: .utf8))
  }

  func parse(_ string: String) throws -> _ParsedColorCube {
    var utf8 = Array(string.utf8)
    // `strtof` may inspect one byte past the final token.
    utf8.append(0)

    return try utf8.withUnsafeBufferPointer { buffer in
      guard let baseAddress = buffer.baseAddress else {
        throw ColorCubeFeatureLoadingError.missingLUT3DSize
      }
      let source = _ColorCubeUTF8Source(
        bytes: UnsafeBufferPointer(
          start: baseAddress,
          count: buffer.count - 1
        )
      )
      return try parse(source)
    }
  }

  private func parse(_ source: _ColorCubeUTF8Source) throws -> _ParsedColorCube {
    var title: String?
    var dimension: Int?
    var domainMin: [Float] = [0, 0, 0]
    var domainMax: [Float] = [1, 1, 1]
    var rgbaValues: [Float] = []
    var lines = _ColorCubeTextLineIterator(source: source)

    while let line = lines.next() {
      var cursor = line.range.lowerBound
      guard let keyword = source.nextToken(in: line, cursor: &cursor) else {
        continue
      }

      if source.token(in: keyword, equalsASCII: "TITLE") {
        title = parseTitle(
          from: line,
          after: keyword,
          source: source
        )
        continue
      }

      if source.token(in: keyword, equalsASCII: "LUT_3D_SIZE") {
        let valueTokens = remainingTokens(
          in: line,
          cursor: &cursor,
          source: source
        )
        let value = valueTokens
          .map(source.string(in:))
          .joined(separator: " ")
        guard
          valueTokens.count == 1,
          let parsedDimension = Int(source.string(in: valueTokens[0])),
          let pixelCount = Self.cubePixelCount(dimension: parsedDimension)
        else {
          throw ColorCubeFeatureLoadingError.invalidLUT3DSize(
            value,
            line: line.number
          )
        }
        dimension = parsedDimension
        rgbaValues.reserveCapacity(pixelCount * 4)
        continue
      }

      if source.token(in: keyword, equalsASCII: "LUT_1D_SIZE") {
        throw ColorCubeFeatureLoadingError.unsupportedLUT1DSize(
          line: line.number
        )
      }

      if source.token(in: keyword, equalsASCII: "DOMAIN_MIN") {
        domainMin = try parseFloatValues(
          in: line,
          cursor: &cursor,
          expectedCount: 3,
          directive: source.string(in: keyword),
          source: source
        )
        continue
      }

      if source.token(in: keyword, equalsASCII: "DOMAIN_MAX") {
        domainMax = try parseFloatValues(
          in: line,
          cursor: &cursor,
          expectedCount: 3,
          directive: source.string(in: keyword),
          source: source
        )
        continue
      }

      if source.token(in: keyword, equalsASCII: "LUT_3D_INPUT_RANGE") {
        let range = try parseFloatValues(
          in: line,
          cursor: &cursor,
          expectedCount: 2,
          directive: source.string(in: keyword),
          source: source
        )
        domainMin = [range[0], range[0], range[0]]
        domainMax = [range[1], range[1], range[1]]
        continue
      }

      guard let red = source.float(in: keyword) else {
        throw ColorCubeFeatureLoadingError.invalidDirective(
          source.string(in: keyword),
          line: line.number
        )
      }
      guard
        red.isFinite,
        let greenToken = source.nextToken(in: line, cursor: &cursor),
        let blueToken = source.nextToken(in: line, cursor: &cursor),
        source.nextToken(in: line, cursor: &cursor) == nil,
        let green = source.float(in: greenToken),
        green.isFinite,
        let blue = source.float(in: blueToken),
        blue.isFinite
      else {
        throw ColorCubeFeatureLoadingError.invalidDataLine(
          source.string(in: line.range),
          line: line.number
        )
      }

      rgbaValues.append(red)
      rgbaValues.append(green)
      rgbaValues.append(blue)
      rgbaValues.append(1)
    }

    guard let dimension else {
      throw ColorCubeFeatureLoadingError.missingLUT3DSize
    }

    guard isDefaultDomain(domainMin: domainMin, domainMax: domainMax) else {
      throw ColorCubeFeatureLoadingError.unsupportedDomain(
        domainMin: domainMin,
        domainMax: domainMax
      )
    }

    let expectedRowCount = dimension * dimension * dimension
    let actualRowCount = rgbaValues.count / 4
    guard actualRowCount == expectedRowCount else {
      throw ColorCubeFeatureLoadingError.mismatchedDataCount(
        expected: expectedRowCount,
        actual: actualRowCount
      )
    }

    return _ParsedColorCube(
      title: title,
      dimension: dimension,
      cubeData: rgbaValues.withUnsafeBufferPointer { Data(buffer: $0) }
    )
  }

  private func parseTitle(
    from line: _ColorCubeTextLine,
    after keyword: Range<Int>,
    source: _ColorCubeUTF8Source
  ) -> String? {
    var start = keyword.upperBound
    while
      start < line.range.upperBound,
      _ColorCubeUTF8Source.isWhitespace(source.bytes[start])
    {
      start += 1
    }
    guard start < line.range.upperBound else {
      return nil
    }

    var titleRange = start..<line.range.upperBound
    if
      titleRange.count >= 2,
      source.bytes[titleRange.lowerBound] == 0x22,
      source.bytes[titleRange.upperBound - 1] == 0x22
    {
      titleRange = (titleRange.lowerBound + 1)..<(titleRange.upperBound - 1)
    }
    return source.string(in: titleRange)
  }

  private func remainingTokens(
    in line: _ColorCubeTextLine,
    cursor: inout Int,
    source: _ColorCubeUTF8Source
  ) -> [Range<Int>] {
    var result: [Range<Int>] = []
    while let token = source.nextToken(in: line, cursor: &cursor) {
      result.append(token)
    }
    return result
  }

  private func parseFloatValues(
    in line: _ColorCubeTextLine,
    cursor: inout Int,
    expectedCount: Int,
    directive: String,
    source: _ColorCubeUTF8Source
  ) throws -> [Float] {
    var values: [Float] = []
    values.reserveCapacity(expectedCount)
    while let token = source.nextToken(in: line, cursor: &cursor) {
      guard let value = source.float(in: token), value.isFinite else {
        throw parseError(
          directive: directive,
          line: source.string(in: line.range),
          lineNumber: line.number
        )
      }
      values.append(value)
    }

    guard values.count == expectedCount else {
      throw parseError(
        directive: directive,
        line: source.string(in: line.range),
        lineNumber: line.number
      )
    }
    return values
  }

  private func parseError(
    directive: String,
    line: String,
    lineNumber: Int
  ) -> ColorCubeFeatureLoadingError {
    let uppercasedDirective = directive.uppercased()
    if
      uppercasedDirective.hasPrefix("DOMAIN")
        || uppercasedDirective == "LUT_3D_INPUT_RANGE"
    {
      return .invalidDomain(line, line: lineNumber)
    }
    return .invalidDataLine(line, line: lineNumber)
  }

  private func isDefaultDomain(
    domainMin: [Float],
    domainMax: [Float]
  ) -> Bool {
    let epsilon = Float(0.000001)
    return zip(domainMin, [0, 0, 0]).allSatisfy {
      abs($0 - Float($1)) <= epsilon
    }
      && zip(domainMax, [1, 1, 1]).allSatisfy {
        abs($0 - Float($1)) <= epsilon
      }
  }

  private static func cubePixelCount(dimension: Int) -> Int? {
    guard dimension > 1 else {
      return nil
    }

    let (square, squareOverflowed) = dimension.multipliedReportingOverflow(
      by: dimension
    )
    let (cube, cubeOverflowed) = square.multipliedReportingOverflow(
      by: dimension
    )
    guard
      squareOverflowed == false,
      cubeOverflowed == false,
      cube <= Int.max / 4
    else {
      return nil
    }
    return cube
  }
}
