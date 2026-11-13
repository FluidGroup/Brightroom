// Copyright (c) 2026 Hiroshi Kimura (Muukii)
//
// Render separate public Shadows and Highlights at their effective strengths.
// The fitter measures how the first output changes the second adjustment's input.
import BrightroomParametric
import CoreImage
import Foundation

let arguments = CommandLine.arguments
precondition(arguments.count == 6, "usage: render-sequential-light input icc new-output.png highlights shadows")
let input = URL(fileURLWithPath: arguments[1])
let profile = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
let destination = URL(fileURLWithPath: arguments[3])
guard let image = CIImage(contentsOf: input, options: [.applyOrientationProperty: true]),
      let colorSpace = CGColorSpace(iccData: profile as CFData),
      let highlights = Double(arguments[4]), let shadows = Double(arguments[5]),
      (-100...100).contains(highlights), (-100...100).contains(shadows) else {
  fatalError("Expected a tagged RGB image, an output ICC and two finite signed slider amounts")
}
precondition(!FileManager.default.fileExists(atPath: destination.path))
let effects = [
  AnyImageEffect(ShadowsFeature(lightroomAmount: shadows)),
  AnyImageEffect(HighlightsFeature(lightroomAmount: highlights)),
]
_ = try ExportRenderer().render(from: image, feature: effects,
  options: .init(resolution: .full, outputFormat: .RGBA16, outputColorSpace: colorSpace,
    output: .file(url: destination, fileType: .png)))
