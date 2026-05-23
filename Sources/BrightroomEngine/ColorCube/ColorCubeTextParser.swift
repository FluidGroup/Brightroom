import Foundation

struct ParsedColorCube {
  let title: String?
  let dimension: Int
  let cubeData: Data
}

enum ColorCubeTextParserError: Error, Equatable, CustomStringConvertible {
  case missingLUT3DSize
  case invalidLUT3DSize(String, line: Int)
  case unsupportedLUT1DSize(line: Int)
  case invalidDirective(String, line: Int)
  case invalidDomain(String, line: Int)
  case unsupportedDomain(domainMin: [Float], domainMax: [Float])
  case invalidDataLine(String, line: Int)
  case mismatchedDataCount(expected: Int, actual: Int)

  var description: String {
    switch self {
    case .missingLUT3DSize:
      return "Missing LUT_3D_SIZE directive."
    case .invalidLUT3DSize(let value, let line):
      return "Invalid LUT_3D_SIZE '\(value)' at line \(line)."
    case .unsupportedLUT1DSize(let line):
      return "LUT_1D_SIZE is not supported at line \(line)."
    case .invalidDirective(let value, let line):
      return "Invalid directive '\(value)' at line \(line)."
    case .invalidDomain(let value, let line):
      return "Invalid domain directive '\(value)' at line \(line)."
    case .unsupportedDomain(let domainMin, let domainMax):
      return "Only the default 0...1 domain is supported, but got DOMAIN_MIN \(domainMin) and DOMAIN_MAX \(domainMax)."
    case .invalidDataLine(let value, let line):
      return "Invalid cube data '\(value)' at line \(line)."
    case .mismatchedDataCount(let expected, let actual):
      return "Expected \(expected) cube data rows, but got \(actual)."
    }
  }
}

struct ColorCubeTextParser {

  func parse(contentsOf url: URL) throws -> ParsedColorCube {
    try parse(String(contentsOf: url, encoding: .utf8))
  }

  func parse(_ string: String) throws -> ParsedColorCube {

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

      if line.uppercased().hasPrefix("TITLE") {
        title = parseTitle(from: line)
        continue
      }

      let tokens = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
      guard let keyword = tokens.first else {
        continue
      }

      switch keyword.uppercased() {
      case "LUT_3D_SIZE":
        guard tokens.count == 2, let parsedDimension = Int(tokens[1]), parsedDimension > 1 else {
          throw ColorCubeTextParserError.invalidLUT3DSize(tokens.dropFirst().joined(separator: " "), line: lineNumber)
        }
        dimension = parsedDimension

      case "LUT_1D_SIZE":
        throw ColorCubeTextParserError.unsupportedLUT1DSize(line: lineNumber)

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
          throw ColorCubeTextParserError.invalidDirective(keyword, line: lineNumber)
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
      throw ColorCubeTextParserError.missingLUT3DSize
    }

    guard isDefaultDomain(domainMin: domainMin, domainMax: domainMax) else {
      throw ColorCubeTextParserError.unsupportedDomain(domainMin: domainMin, domainMax: domainMax)
    }

    let expectedRowCount = dimension * dimension * dimension
    guard rows.count == expectedRowCount else {
      throw ColorCubeTextParserError.mismatchedDataCount(expected: expectedRowCount, actual: rows.count)
    }

    var rgbaValues: [Float] = []
    rgbaValues.reserveCapacity(expectedRowCount * 4)

    for row in rows {
      rgbaValues.append(row[0])
      rgbaValues.append(row[1])
      rgbaValues.append(row[2])
      rgbaValues.append(1)
    }

    let cubeData = rgbaValues.withUnsafeBufferPointer {
      Data(buffer: $0)
    }

    return ParsedColorCube(
      title: title,
      dimension: dimension,
      cubeData: cubeData
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
    } else {
      return title
    }
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
      if directive.hasPrefix("DOMAIN") || directive == "LUT_3D_INPUT_RANGE" {
        throw ColorCubeTextParserError.invalidDomain(line, line: lineNumber)
      } else {
        throw ColorCubeTextParserError.invalidDataLine(line, line: lineNumber)
      }
    }

    let values = valueTokens.compactMap { token -> Float? in
      guard let value = Float(token), value.isFinite else {
        return nil
      }
      return value
    }

    guard values.count == expectedCount else {
      if directive.hasPrefix("DOMAIN") || directive == "LUT_3D_INPUT_RANGE" {
        throw ColorCubeTextParserError.invalidDomain(line, line: lineNumber)
      } else {
        throw ColorCubeTextParserError.invalidDataLine(line, line: lineNumber)
      }
    }

    return values
  }

  private func isDefaultDomain(domainMin: [Float], domainMax: [Float]) -> Bool {
    let epsilon = Float(0.000001)

    return zip(domainMin, [0, 0, 0]).allSatisfy { abs($0 - Float($1)) <= epsilon }
      && zip(domainMax, [1, 1, 1]).allSatisfy { abs($0 - Float($1)) <= epsilon }
  }
}
