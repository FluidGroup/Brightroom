//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import Foundation

/// The internal representation produced while parsing a `.cube` text file.
struct _ParsedColorCube {
  let title: String?
  let dimension: Int
  let cubeData: Data
}

/// Parses three-dimensional `.cube` text without exposing parser mechanics as
/// part of BrightroomParametric's public surface.
struct _ColorCubeTextParser {

  func parse(contentsOf url: URL) throws -> _ParsedColorCube {
    try parse(String(contentsOf: url, encoding: .utf8))
  }

  func parse(_ string: String) throws -> _ParsedColorCube {
    var title: String?
    var dimension: Int?
    var domainMin: [Float] = [0, 0, 0]
    var domainMax: [Float] = [1, 1, 1]
    var rows: [[Float]] = []

    for (lineIndex, rawLine) in string.components(separatedBy: .newlines).enumerated() {
      let lineNumber = lineIndex + 1
      let line = rawLine
        .components(separatedBy: "#")
        .first?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

      guard line.isEmpty == false else {
        continue
      }

      let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
      guard let keyword = tokens.first else {
        continue
      }

      switch keyword.uppercased() {
      case "TITLE":
        title = parseTitle(from: line)

      case "LUT_3D_SIZE":
        let value = tokens.dropFirst().joined(separator: " ")
        guard tokens.count == 2,
              let parsedDimension = Int(tokens[1]),
              Self.cubePixelCount(dimension: parsedDimension) != nil
        else {
          throw ColorCubeFeatureLoadingError.invalidLUT3DSize(
            value,
            line: lineNumber
          )
        }
        dimension = parsedDimension

      case "LUT_1D_SIZE":
        throw ColorCubeFeatureLoadingError.unsupportedLUT1DSize(line: lineNumber)

      case "DOMAIN_MIN":
        domainMin = try parseFloatValues(
          from: tokens,
          expectedCount: 3,
          directive: keyword,
          line: line,
          lineNumber: lineNumber
        )

      case "DOMAIN_MAX":
        domainMax = try parseFloatValues(
          from: tokens,
          expectedCount: 3,
          directive: keyword,
          line: line,
          lineNumber: lineNumber
        )

      case "LUT_3D_INPUT_RANGE":
        let range = try parseFloatValues(
          from: tokens,
          expectedCount: 2,
          directive: keyword,
          line: line,
          lineNumber: lineNumber
        )
        domainMin = [range[0], range[0], range[0]]
        domainMax = [range[1], range[1], range[1]]

      default:
        guard Float(keyword) != nil else {
          throw ColorCubeFeatureLoadingError.invalidDirective(
            keyword,
            line: lineNumber
          )
        }

        rows.append(
          try parseFloatValues(
            from: ["DATA"] + tokens,
            expectedCount: 3,
            directive: "DATA",
            line: line,
            lineNumber: lineNumber
          )
        )
      }
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
    guard rows.count == expectedRowCount else {
      throw ColorCubeFeatureLoadingError.mismatchedDataCount(
        expected: expectedRowCount,
        actual: rows.count
      )
    }

    var rgbaValues: [Float] = []
    rgbaValues.reserveCapacity(expectedRowCount * 4)
    for row in rows {
      rgbaValues.append(contentsOf: [row[0], row[1], row[2], 1])
    }

    return _ParsedColorCube(
      title: title,
      dimension: dimension,
      cubeData: rgbaValues.withUnsafeBufferPointer { Data(buffer: $0) }
    )
  }

  private func parseTitle(from line: String) -> String? {
    let title = String(line.dropFirst("TITLE".count))
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard title.isEmpty == false else {
      return nil
    }

    if title.hasPrefix("\""), title.hasSuffix("\""), title.count >= 2 {
      return String(title.dropFirst().dropLast())
    }
    return title
  }

  private func parseFloatValues(
    from tokens: [String],
    expectedCount: Int,
    directive: String,
    line: String,
    lineNumber: Int
  ) throws -> [Float] {
    let valueTokens = Array(tokens.dropFirst())
    guard valueTokens.count == expectedCount else {
      throw parseError(
        directive: directive,
        line: line,
        lineNumber: lineNumber
      )
    }

    let values = valueTokens.compactMap { token -> Float? in
      guard let value = Float(token), value.isFinite else {
        return nil
      }
      return value
    }

    guard values.count == expectedCount else {
      throw parseError(
        directive: directive,
        line: line,
        lineNumber: lineNumber
      )
    }
    return values
  }

  private func parseError(
    directive: String,
    line: String,
    lineNumber: Int
  ) -> ColorCubeFeatureLoadingError {
    if directive.hasPrefix("DOMAIN") || directive == "LUT_3D_INPUT_RANGE" {
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

    let (square, squareOverflowed) = dimension.multipliedReportingOverflow(by: dimension)
    let (cube, cubeOverflowed) = square.multipliedReportingOverflow(by: dimension)
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
