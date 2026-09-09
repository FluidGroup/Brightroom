import BrightroomEngine
import BrightroomParametric
import BrightroomUI
import CoreImage
import Foundation
import SwiftUI
import UIKit

struct ParametricFeaturePreviewView: View {

  @State private var isFirstCropEnabled = true
  @State private var firstCropInset: Double = 28
  @State private var isSecondCropEnabled = true
  @State private var secondCropInset: Double = 20

  @State private var isLocalExposureEnabled = true
  @State private var localExposureValue: Double = 0.9
  @State private var localExposureX: Double = 0.34
  @State private var localExposureY: Double = 0.5
  @State private var localExposureDiameter: Double = 0.34

  @State private var isLocalBlurEnabled = true
  @State private var localBlurRadius: Double = 10
  @State private var localBlurX: Double = 0.68
  @State private var localBlurY: Double = 0.5
  @State private var localBlurDiameter: Double = 0.42

  @State private var globalBrightness: Double = 0.04
  @State private var previewLayer: ParametricPreviewLayer = .output

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section("Preview") {
          Picker("Layer", selection: $previewLayer) {
            ForEach(ParametricPreviewLayer.allCases) { layer in
              Text(layer.title).tag(layer)
            }
          }
        }

        Section("Crop") {
          Toggle("Crop A", isOn: $isFirstCropEnabled)
          Slider(
            value: $firstCropInset,
            in: 0...120,
            step: 1
          ) {
            Text("Inset A")
          }

          Toggle("Crop B", isOn: $isSecondCropEnabled)
          Slider(
            value: $secondCropInset,
            in: 0...100,
            step: 1
          ) {
            Text("Inset B")
          }
        }

        Section("Local Exposure") {
          Toggle("Enabled", isOn: $isLocalExposureEnabled)
          Slider(value: $localExposureValue, in: -1...2, step: 0.05) {
            Text("EV")
          }
          Slider(value: $localExposureX, in: 0...1, step: 0.01) {
            Text("X")
          }
          Slider(value: $localExposureY, in: 0...1, step: 0.01) {
            Text("Y")
          }
          Slider(value: $localExposureDiameter, in: 0.08...0.9, step: 0.01) {
            Text("Size")
          }
        }

        Section("Local Blur") {
          Toggle("Enabled", isOn: $isLocalBlurEnabled)
          Slider(value: $localBlurRadius, in: 0...40, step: 1) {
            Text("Radius")
          }
          Slider(value: $localBlurX, in: 0...1, step: 0.01) {
            Text("X")
          }
          Slider(value: $localBlurY, in: 0...1, step: 0.01) {
            Text("Y")
          }
          Slider(value: $localBlurDiameter, in: 0.08...0.9, step: 0.01) {
            Text("Size")
          }
        }

        Section("Global") {
          Slider(value: $globalBrightness, in: -0.25...0.25, step: 0.01) {
            Text("Brightness")
          }
        }

        Section("Tree") {
          Text(treeDescription)
            .font(.caption.monospaced())
        }
      }
      .frame(maxHeight: 520)

      previewSurface
    }
    .navigationTitle("Parametric Features")
  }

  @ViewBuilder
  private var previewSurface: some View {
    switch makePreviewImage() {
    case let .image(image):
      SwiftUIMetalImageView(
        image: image,
        contentMode: .scaleAspectFit,
        displayBackground: .color(.black)
      )
      .background(Color.black)
    case let .failure(message):
      Text(message)
        .font(.footnote.monospaced())
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
  }

  private var treeDescription: String {
    let outputSize = currentDomainSize
    return [
      isFirstCropEnabled ? "Crop A inset=\(Int(firstCropInset))" : "Crop A disabled",
      isSecondCropEnabled ? "Crop B inset=\(Int(secondCropInset))" : "Crop B disabled",
      isLocalExposureEnabled ? "Local Exposure ev=\(formatted(localExposureValue))" : "Local Exposure disabled",
      isLocalBlurEnabled ? "Local Blur radius=\(Int(localBlurRadius))" : "Local Blur disabled",
      "Global Brightness=\(formatted(globalBrightness))",
      "Output domain \(Int(outputSize.width)) x \(Int(outputSize.height))",
    ]
    .joined(separator: "\n")
  }

  private func makePreviewImage() -> ParametricPreviewImage {
    do {
      let renderer = ParametricImageRenderer()
      let output = try renderer.makeOutput(
        from: Self.sourceImage,
        document: makeDocument()
      )

      switch previewLayer {
      case .source:
        return .image(Self.sourceImage)
      case .output:
        return .image(output.image)
      case .localExposureMask:
        return .image(
          output.localAdjustmentMasks[Self.localExposureID]
            ?? CIImage.parametricPreviewTransparent(extent: output.image.extent)
        )
      case .localBlurMask:
        return .image(
          output.localAdjustmentMasks[Self.localBlurID]
            ?? CIImage.parametricPreviewTransparent(extent: output.image.extent)
        )
      }
    } catch {
      return .failure(String(describing: error))
    }
  }

  private func makeDocument() -> EditingDocument {
    var features: [MainFeature] = [
      .domain(
        CropFeature(
          id: Self.firstCropID,
          isEnabled: isFirstCropEnabled,
          cropRect: firstCropRect
        )
      ),
      .domain(
        CropFeature(
          id: Self.secondCropID,
          isEnabled: isSecondCropEnabled,
          cropRect: secondCropRect
        )
      ),
      .localAdjustment(
        LocalAdjustmentFeature(
          id: Self.localExposureID,
          isEnabled: isLocalExposureEnabled,
          maskTree: MaskTree(root: localExposureMask),
          effectPipeline: EffectPipeline(
            effects: [
              ExposureFeature(
                id: FeatureID(rawValue: "preview-local-exposure-effect"),
                value: localExposureValue
              ),
            ]
          )
        )
      ),
      .localAdjustment(
        LocalAdjustmentFeature(
          id: Self.localBlurID,
          isEnabled: isLocalBlurEnabled,
          maskTree: MaskTree(root: localBlurMask),
          effectPipeline: EffectPipeline(
            effects: [
              GaussianBlurFeature(
                id: FeatureID(rawValue: "preview-local-blur-effect"),
                radius: localBlurRadius
              ),
            ]
          )
        )
      ),
    ]

    if abs(globalBrightness) > 0.001 {
      features.append(
        .effect(
          BrightnessFeature(
            id: FeatureID(rawValue: "preview-global-brightness"),
            value: globalBrightness
          )
        )
      )
    }

    return EditingDocument(mainTree: MainTree(features: features))
  }

  private var firstCropRect: CGRect {
    let inset = CGFloat(firstCropInset)
    return CGRect(
      x: inset,
      y: inset * 0.5,
      width: max(Self.sourceExtent.width - inset * 2, 1),
      height: max(Self.sourceExtent.height - inset, 1)
    )
  }

  private var secondCropRect: CGRect {
    let baseSize = sizeAfterFirstCrop
    let inset = CGFloat(secondCropInset)
    return CGRect(
      x: inset,
      y: inset * 0.5,
      width: max(baseSize.width - inset * 2, 1),
      height: max(baseSize.height - inset, 1)
    )
  }

  private var sizeAfterFirstCrop: CGSize {
    guard isFirstCropEnabled else {
      return Self.sourceExtent.size
    }
    return firstCropRect.size
  }

  private var currentDomainSize: CGSize {
    guard isSecondCropEnabled else {
      return sizeAfterFirstCrop
    }
    return secondCropRect.size
  }

  private var localExposureMask: MaskNode {
    .brush(
      BrushMask(
        id: FeatureID(rawValue: "preview-local-exposure-mask"),
        strokes: [
          BrushMaskStroke(
            stamps: [normalizedPoint(x: localExposureX, y: localExposureY)],
            brush: BrushMaskBrush(
              diameter: normalizedDiameter(localExposureDiameter),
              hardness: 0.55,
              opacity: 1
            )
          ),
        ]
      )
    )
  }

  private var localBlurMask: MaskNode {
    .feather(
      MaskFeather(
        id: FeatureID(rawValue: "preview-local-blur-feather"),
        input: .brush(
          BrushMask(
            id: FeatureID(rawValue: "preview-local-blur-mask"),
            strokes: [
              BrushMaskStroke(
                stamps: [normalizedPoint(x: localBlurX, y: localBlurY)],
                brush: BrushMaskBrush(
                  diameter: normalizedDiameter(localBlurDiameter),
                  hardness: 0.45,
                  opacity: 1
                )
              ),
            ]
          )
        ),
        radius: 6
      )
    )
  }

  private func normalizedPoint(x: Double, y: Double) -> CGPoint {
    CGPoint(
      x: currentDomainSize.width * CGFloat(x),
      y: currentDomainSize.height * CGFloat(y)
    )
  }

  private func normalizedDiameter(_ value: Double) -> Double {
    Double(min(currentDomainSize.width, currentDomainSize.height)) * value
  }

  private func formatted(_ value: Double) -> String {
    String(format: "%.2f", value)
  }

  private static let firstCropID = FeatureID(rawValue: "preview-crop-a")
  private static let secondCropID = FeatureID(rawValue: "preview-crop-b")
  private static let localExposureID = FeatureID(rawValue: "preview-local-exposure")
  private static let localBlurID = FeatureID(rawValue: "preview-local-blur")

  private static let sourceExtent = CGRect(x: 0, y: 0, width: 512, height: 320)

  private static let sourceImage: CIImage = {
    let checker = CIFilter(
      name: "CICheckerboardGenerator",
      parameters: [
        "inputCenter": CIVector(x: 0, y: 0),
        "inputColor0": CIColor(red: 0.12, green: 0.18, blue: 0.23, alpha: 1),
        "inputColor1": CIColor(red: 0.62, green: 0.68, blue: 0.58, alpha: 1),
        "inputWidth": 48,
        "inputSharpness": 0.7,
      ]
    )!
    .outputImage!
    .cropped(to: sourceExtent)

    let warmBand = CIImage(color: CIColor(red: 0.95, green: 0.35, blue: 0.18, alpha: 0.78))
      .cropped(to: CGRect(x: 214, y: 0, width: 42, height: sourceExtent.height))
      .applyingFilter(
        "CISourceOverCompositing",
        parameters: [kCIInputBackgroundImageKey: checker]
      )

    let coolBand = CIImage(color: CIColor(red: 0.06, green: 0.46, blue: 0.9, alpha: 0.72))
      .cropped(to: CGRect(x: 360, y: 0, width: 60, height: sourceExtent.height))
      .applyingFilter(
        "CISourceOverCompositing",
        parameters: [kCIInputBackgroundImageKey: warmBand]
      )

    return CIFilter(
      name: "CIRadialGradient",
      parameters: [
        "inputCenter": CIVector(x: 128, y: 214),
        "inputRadius0": 20,
        "inputRadius1": 154,
        "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 0.82),
        "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 0),
      ]
    )!
    .outputImage!
    .cropped(to: sourceExtent)
    .applyingFilter(
      "CISourceOverCompositing",
      parameters: [kCIInputBackgroundImageKey: coolBand]
    )
    .cropped(to: sourceExtent)
  }()
}

/// Image evaluation state for the parametric feature preview.
private enum ParametricPreviewImage {
  case image(CIImage)
  case failure(String)
}

/// Layers that can be inspected in the parametric feature preview.
private enum ParametricPreviewLayer: CaseIterable, Identifiable {
  case source
  case output
  case localExposureMask
  case localBlurMask

  var id: Self { self }

  var title: String {
    switch self {
    case .source:
      "Source"
    case .output:
      "Output"
    case .localExposureMask:
      "Exposure Mask"
    case .localBlurMask:
      "Blur Mask"
    }
  }
}

private extension CIImage {

  static func parametricPreviewTransparent(extent: CGRect) -> CIImage {
    CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
      .cropped(to: extent)
  }
}
