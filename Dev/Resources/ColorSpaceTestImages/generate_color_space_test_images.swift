import AppKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

private struct ProfileTarget {
  let fileName: String
  let colorSpaceName: CFString
}

private let outputDirectory = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()

private let targets: [ProfileTarget] = [
  .init(fileName: "colorspace-probe-srgb.png", colorSpaceName: CGColorSpace.sRGB),
  .init(fileName: "colorspace-probe-display-p3.png", colorSpaceName: CGColorSpace.displayP3),
  .init(fileName: "colorspace-probe-adobe-rgb-1998.png", colorSpaceName: CGColorSpace.adobeRGB1998),
]

private let width = 768
private let height = 512
private let bytesPerPixel = 4
private let bytesPerRow = width * bytesPerPixel
private let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
private let displayP3ColorSpace = CGColorSpace(name: CGColorSpace.displayP3)!

private struct ChromaticityPoint {
  let x: CGFloat
  let y: CGFloat
}

private struct RGBPrimaries {
  let red: ChromaticityPoint
  let green: ChromaticityPoint
  let blue: ChromaticityPoint
}

private let sRGBPrimaries = RGBPrimaries(
  red: .init(x: 0.640, y: 0.330),
  green: .init(x: 0.300, y: 0.600),
  blue: .init(x: 0.150, y: 0.060)
)

private let displayP3Primaries = RGBPrimaries(
  red: .init(x: 0.680, y: 0.320),
  green: .init(x: 0.265, y: 0.690),
  blue: .init(x: 0.150, y: 0.060)
)

private let d65WhitePoint = ChromaticityPoint(x: 0.3127, y: 0.3290)

private let swatches: [(name: String, rgba: (UInt8, UInt8, UInt8, UInt8))] = [
  ("red", (255, 0, 0, 255)),
  ("green", (0, 255, 0, 255)),
  ("blue", (0, 0, 255, 255)),
  ("yellow", (255, 255, 0, 255)),
  ("cyan", (0, 255, 255, 255)),
  ("magenta", (255, 0, 255, 255)),
  ("orange", (255, 128, 0, 255)),
  ("skin", (216, 148, 116, 255)),
  ("gray25", (64, 64, 64, 255)),
  ("gray50", (128, 128, 128, 255)),
  ("gray75", (192, 192, 192, 255)),
  ("white", (255, 255, 255, 255)),
]

private func makePixelBuffer() -> [UInt8] {
  var pixels = Array(repeating: UInt8(255), count: bytesPerRow * height)

  func setPixel(x: Int, y: Int, rgba: (UInt8, UInt8, UInt8, UInt8)) {
    guard x >= 0, y >= 0, x < width, y < height else {
      return
    }

    let offset = y * bytesPerRow + x * bytesPerPixel
    pixels[offset + 0] = rgba.0
    pixels[offset + 1] = rgba.1
    pixels[offset + 2] = rgba.2
    pixels[offset + 3] = rgba.3
  }

  func fillRect(x: Int, y: Int, w: Int, h: Int, rgba: (UInt8, UInt8, UInt8, UInt8)) {
    for row in y..<(y + h) {
      for column in x..<(x + w) {
        setPixel(x: column, y: row, rgba: rgba)
      }
    }
  }

  fillRect(x: 0, y: 0, w: width, h: height, rgba: (18, 18, 18, 255))

  let margin = 32
  let gap = 12
  let swatchWidth = (width - margin * 2 - gap * 3) / 4
  let swatchHeight = 92

  for (index, swatch) in swatches.enumerated() {
    let column = index % 4
    let row = index / 4
    let x = margin + column * (swatchWidth + gap)
    let y = margin + row * (swatchHeight + gap)
    fillRect(x: x, y: y, w: swatchWidth, h: swatchHeight, rgba: swatch.rgba)
  }

  let rampY = height - 96
  let rampHeight = 28
  for x in margin..<(width - margin) {
    let value = UInt8((x - margin) * 255 / max(width - margin * 2 - 1, 1))
    fillRect(x: x, y: rampY, w: 1, h: rampHeight, rgba: (value, value, value, 255))
    fillRect(x: x, y: rampY + 40, w: 1, h: rampHeight, rgba: (value, 255, value, 255))
  }

  return pixels
}

private func makeImage(colorSpace: CGColorSpace) -> CGImage {
  let pixels = makePixelBuffer()
  let data = Data(pixels)
  guard let provider = CGDataProvider(data: data as CFData) else {
    fatalError("Failed to create data provider")
  }

  let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
  guard let image = CGImage(
    width: width,
    height: height,
    bitsPerComponent: 8,
    bitsPerPixel: 32,
    bytesPerRow: bytesPerRow,
    space: colorSpace,
    bitmapInfo: bitmapInfo,
    provider: provider,
    decode: nil,
    shouldInterpolate: false,
    intent: .defaultIntent
  ) else {
    fatalError("Failed to create image")
  }

  return image
}

private func writePNG(_ image: CGImage, to url: URL) {
  guard let destination = CGImageDestinationCreateWithURL(
    url as CFURL,
    UTType.png.identifier as CFString,
    1,
    nil
  ) else {
    fatalError("Failed to create image destination: \(url.path)")
  }

  CGImageDestinationAddImage(destination, image, [
    kCGImagePropertyPNGDictionary: [:]
  ] as CFDictionary)

  guard CGImageDestinationFinalize(destination) else {
    fatalError("Failed to finalize PNG: \(url.path)")
  }
}

private func makeColor(
  _ components: (CGFloat, CGFloat, CGFloat, CGFloat),
  colorSpace: CGColorSpace
) -> CGColor {
  guard let color = CGColor(
    colorSpace: colorSpace,
    components: [
      components.0,
      components.1,
      components.2,
      components.3,
    ]
  ) else {
    fatalError("Failed to create color")
  }

  return color
}

private func convertedColor(
  _ components: (CGFloat, CGFloat, CGFloat, CGFloat),
  from source: CGColorSpace,
  to destination: CGColorSpace
) -> CGColor {
  let sourceColor = makeColor(components, colorSpace: source)
  guard let converted = sourceColor.converted(
    to: destination,
    intent: .relativeColorimetric,
    options: nil
  ) else {
    fatalError("Failed to convert color")
  }

  return converted
}

private func drawText(
  _ text: String,
  in context: CGContext,
  color: CGColor,
  fontSize: CGFloat,
  baseline: CGPoint
) {
  let font = CTFontCreateWithName("HelveticaNeue-CondensedBlack" as CFString, fontSize, nil)
  let attributedString = NSAttributedString(
    string: text,
    attributes: [
      .font: font,
      .foregroundColor: color,
      .kern: -2,
    ]
  )
  let line = CTLineCreateWithAttributedString(attributedString)

  context.saveGState()
  context.setShouldAntialias(false)
  context.textPosition = baseline
  CTLineDraw(line, context)
  context.restoreGState()
}

private func drawVisibleLabel(
  _ text: String,
  in context: CGContext,
  baseline: CGPoint
) {
  let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 26, nil)
  let attributedString = NSAttributedString(
    string: text,
    attributes: [
      .font: font,
      .foregroundColor: makeColor((1, 1, 1, 1), colorSpace: displayP3ColorSpace),
    ]
  )
  let line = CTLineCreateWithAttributedString(attributedString)

  context.saveGState()
  context.textPosition = baseline
  CTLineDraw(line, context)
  context.restoreGState()
}

private func makeP3HiddenTextImage() -> CGImage {
  guard let context = CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: displayP3ColorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  ) else {
    fatalError("Failed to create hidden text context")
  }

  let dark = makeColor((0.04, 0.04, 0.04, 1), colorSpace: displayP3ColorSpace)
  context.setFillColor(dark)
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))

  let sRGBRedInP3 = convertedColor(
    (1, 0, 0, 1),
    from: sRGBColorSpace,
    to: displayP3ColorSpace
  )
  let p3Red = makeColor((1, 0, 0, 1), colorSpace: displayP3ColorSpace)

  let sRGBGreenInP3 = convertedColor(
    (0, 1, 0, 1),
    from: sRGBColorSpace,
    to: displayP3ColorSpace
  )
  let p3Green = makeColor((0, 1, 0, 1), colorSpace: displayP3ColorSpace)

  context.setFillColor(sRGBRedInP3)
  context.fill(CGRect(x: 32, y: 280, width: 704, height: 168))
  drawText(
    "P3 ONLY",
    in: context,
    color: p3Red,
    fontSize: 124,
    baseline: CGPoint(x: 88, y: 330)
  )

  context.setFillColor(sRGBGreenInP3)
  context.fill(CGRect(x: 32, y: 64, width: 704, height: 168))
  drawText(
    "WIDE GREEN",
    in: context,
    color: p3Green,
    fontSize: 94,
    baseline: CGPoint(x: 74, y: 120)
  )

  drawVisibleLabel(
    "If color management reaches a P3 display, letters appear in the panels.",
    in: context,
    baseline: CGPoint(x: 32, y: 478)
  )
  drawVisibleLabel(
    "If this is flattened to sRGB, the panel text should nearly disappear.",
    in: context,
    baseline: CGPoint(x: 32, y: 34)
  )

  guard let image = context.makeImage() else {
    fatalError("Failed to make hidden text image")
  }

  return image
}

private func makeSRGBClippedReference(from image: CGImage) -> CGImage {
  let ciContext = CIContext(options: [.workingFormat: CIFormat.RGBAh])
  let ciImage = CIImage(cgImage: image)
  guard let clipped = ciContext.createCGImage(
    ciImage,
    from: ciImage.extent,
    format: .RGBA8,
    colorSpace: sRGBColorSpace
  ) else {
    fatalError("Failed to make sRGB clipped reference")
  }

  return clipped
}

private func makePixelImage(
  pixels: [UInt8],
  colorSpace: CGColorSpace
) -> CGImage {
  guard let provider = CGDataProvider(data: Data(pixels) as CFData) else {
    fatalError("Failed to create data provider")
  }

  let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
  guard let image = CGImage(
    width: width,
    height: height,
    bitsPerComponent: 8,
    bitsPerPixel: 32,
    bytesPerRow: bytesPerRow,
    space: colorSpace,
    bitmapInfo: bitmapInfo,
    provider: provider,
    decode: nil,
    shouldInterpolate: false,
    intent: .defaultIntent
  ) else {
    fatalError("Failed to create pixel image")
  }

  return image
}

private func gammaEncodeSRGB(_ value: CGFloat) -> CGFloat {
  let clamped = min(max(value, 0), 1)
  if clamped <= 0.0031308 {
    return 12.92 * clamped
  } else {
    return 1.055 * pow(clamped, 1.0 / 2.4) - 0.055
  }
}

private func displayP3RGBFromXYZ(
  x: CGFloat,
  y: CGFloat,
  z: CGFloat
) -> (CGFloat, CGFloat, CGFloat) {
  // XYZ D65 to linear Display P3.
  let r = 2.4934969 * x - 0.9313836 * y - 0.4027107 * z
  let g = -0.8294890 * x + 1.7626640 * y + 0.0236247 * z
  let b = 0.0358458 * x - 0.0761724 * y + 0.9568845 * z
  return (
    gammaEncodeSRGB(r),
    gammaEncodeSRGB(g),
    gammaEncodeSRGB(b)
  )
}

private func makeGamutMapBackgroundPixels() -> [UInt8] {
  var pixels = Array(repeating: UInt8(255), count: bytesPerRow * height)

  func setPixel(x: Int, y: Int, rgba: (UInt8, UInt8, UInt8, UInt8)) {
    let offset = y * bytesPerRow + x * bytesPerPixel
    pixels[offset + 0] = rgba.0
    pixels[offset + 1] = rgba.1
    pixels[offset + 2] = rgba.2
    pixels[offset + 3] = rgba.3
  }

  for row in 0..<height {
    for column in 0..<width {
      let chromaX = CGFloat(column) / CGFloat(width - 1) * 0.80
      let chromaY = (1 - CGFloat(row) / CGFloat(height - 1)) * 0.90

      guard chromaY > 0.001, chromaX + chromaY <= 1.05 else {
        setPixel(x: column, y: row, rgba: (8, 8, 10, 255))
        continue
      }

      let xyzX = chromaX / chromaY
      let xyzY: CGFloat = 1
      let xyzZ = max((1 - chromaX - chromaY) / chromaY, 0)
      let rgb = displayP3RGBFromXYZ(x: xyzX, y: xyzY, z: xyzZ)
      let yShade = CGFloat(row) / CGFloat(height - 1)
      let shade = 0.22 + 0.78 * (1 - yShade)

      setPixel(
        x: column,
        y: row,
        rgba: (
          UInt8(min(max(rgb.0 * shade * 255, 0), 255)),
          UInt8(min(max(rgb.1 * shade * 255, 0), 255)),
          UInt8(min(max(rgb.2 * shade * 255, 0), 255)),
          255
        )
      )
    }
  }

  return pixels
}

private func drawGamutTriangle(
  _ primaries: RGBPrimaries,
  in context: CGContext,
  strokeColor: CGColor,
  lineWidth: CGFloat
) {
  func point(_ chromaticity: ChromaticityPoint) -> CGPoint {
    CGPoint(
      x: chromaticity.x / 0.80 * CGFloat(width),
      y: (1 - chromaticity.y / 0.90) * CGFloat(height)
    )
  }

  context.saveGState()
  context.setStrokeColor(strokeColor)
  context.setLineWidth(lineWidth)
  context.setLineJoin(.round)
  context.setLineCap(.round)
  context.beginPath()
  context.move(to: point(primaries.red))
  context.addLine(to: point(primaries.green))
  context.addLine(to: point(primaries.blue))
  context.closePath()
  context.strokePath()
  context.restoreGState()
}

private func drawD65WhitePoint(in context: CGContext) {
  let center = CGPoint(
    x: d65WhitePoint.x / 0.80 * CGFloat(width),
    y: (1 - d65WhitePoint.y / 0.90) * CGFloat(height)
  )

  context.saveGState()
  context.setFillColor(makeColor((1, 1, 1, 1), colorSpace: displayP3ColorSpace))
  context.setStrokeColor(makeColor((0.45, 0.72, 1, 0.75), colorSpace: displayP3ColorSpace))
  context.setLineWidth(8)
  context.strokeEllipse(in: CGRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20))
  context.fillEllipse(in: CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12))
  context.restoreGState()
}

private func drawGamutMapLabels(in context: CGContext) {
  func label(_ text: String, color: CGColor, baseline: CGPoint) {
    let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 22, nil)
    let attributedString = NSAttributedString(
      string: text,
      attributes: [
        .font: font,
        .foregroundColor: color,
      ]
    )
    let line = CTLineCreateWithAttributedString(attributedString)

    context.saveGState()
    context.textPosition = baseline
    CTLineDraw(line, context)
    context.restoreGState()
  }

  label(
    "Display P3",
    color: makeColor((0.12, 0.44, 1, 1), colorSpace: displayP3ColorSpace),
    baseline: CGPoint(x: 538, y: 450)
  )
  label(
    "sRGB",
    color: makeColor((1, 0.14, 0.12, 1), colorSpace: displayP3ColorSpace),
    baseline: CGPoint(x: 535, y: 420)
  )
  label(
    "D65",
    color: makeColor((1, 1, 1, 1), colorSpace: displayP3ColorSpace),
    baseline: CGPoint(x: 338, y: 288)
  )
}

private func makeGamutMapImage() -> CGImage {
  let background = makePixelImage(
    pixels: makeGamutMapBackgroundPixels(),
    colorSpace: displayP3ColorSpace
  )

  guard let context = CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: displayP3ColorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  ) else {
    fatalError("Failed to create gamut map context")
  }

  context.draw(background, in: CGRect(x: 0, y: 0, width: width, height: height))

  drawGamutTriangle(
    sRGBPrimaries,
    in: context,
    strokeColor: makeColor((1, 0.14, 0.12, 1), colorSpace: displayP3ColorSpace),
    lineWidth: 4
  )
  drawGamutTriangle(
    displayP3Primaries,
    in: context,
    strokeColor: makeColor((0.12, 0.44, 1, 1), colorSpace: displayP3ColorSpace),
    lineWidth: 4
  )
  drawD65WhitePoint(in: context)
  drawGamutMapLabels(in: context)

  guard let image = context.makeImage() else {
    fatalError("Failed to make gamut map image")
  }

  return image
}

for target in targets {
  guard let colorSpace = CGColorSpace(name: target.colorSpaceName) else {
    fatalError("Unsupported color space: \(target.colorSpaceName)")
  }

  let image = makeImage(colorSpace: colorSpace)
  let url = outputDirectory.appendingPathComponent(target.fileName)
  writePNG(image, to: url)
  print("Wrote \(url.path)")
}

let hiddenTextImage = makeP3HiddenTextImage()
let hiddenTextURL = outputDirectory.appendingPathComponent("colorspace-p3-hidden-text.png")
writePNG(hiddenTextImage, to: hiddenTextURL)
print("Wrote \(hiddenTextURL.path)")

let clippedReference = makeSRGBClippedReference(from: hiddenTextImage)
let clippedReferenceURL = outputDirectory.appendingPathComponent(
  "colorspace-p3-hidden-text-srgb-clipped-reference.png"
)
writePNG(clippedReference, to: clippedReferenceURL)
print("Wrote \(clippedReferenceURL.path)")

let gamutMapImage = makeGamutMapImage()
let gamutMapURL = outputDirectory.appendingPathComponent("colorspace-gamut-map-display-p3.png")
writePNG(gamutMapImage, to: gamutMapURL)
print("Wrote \(gamutMapURL.path)")

let gamutMapClippedReference = makeSRGBClippedReference(from: gamutMapImage)
let gamutMapClippedReferenceURL = outputDirectory.appendingPathComponent(
  "colorspace-gamut-map-srgb-clipped-reference.png"
)
writePNG(gamutMapClippedReference, to: gamutMapClippedReferenceURL)
print("Wrote \(gamutMapClippedReferenceURL.path)")
