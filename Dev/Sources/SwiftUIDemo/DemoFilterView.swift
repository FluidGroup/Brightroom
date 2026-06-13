
import BrightroomEngine
import BrightroomParametric
import BrightroomUI
import SwiftUI
import UIKit

/// Custom effects registered into the editing document. Effects are value
/// types with stable identities; the parametric runtime evaluates them through
/// `ImageEffectFeatureType.apply(to:context:)`.
struct DemoInvertFeature: ImageEffectFeatureType {
  var id: FeatureID = .init(rawValue: "demo.invert")
  var isEnabled: Bool = true

  func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    image
      .applyingFilter("CIColorInvert")
  }
}

struct DemoGrayscaleFeature: ImageEffectFeatureType {
  var id: FeatureID = .init(rawValue: "demo.grayscale")
  var isEnabled: Bool = true

  func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    let kernel = CIKernel(source: """
                  kernel vec4 customGrayscale(__sample pixel) {
                      float grayscale = dot(pixel.rgb, vec3(0.299, 0.587, 0.114));
                      return vec4(grayscale, grayscale, grayscale, pixel.a);
                  }
                  """)!
    let output = kernel.apply(
      extent: image.extent,
      roiCallback: { _, rect in
        rect
      },
      arguments: [image]
    )

    return output!
  }
}

struct DemoMotionBlurFeature: ImageEffectFeatureType {
  var id: FeatureID = .init(rawValue: "demo.motion-blur")
  var isEnabled: Bool = true

  private static nonisolated(unsafe) let kernel = CIKernel(source:
"""
    kernel vec4 motionBlur(sampler image, vec2 size, float sampleCount, float blur) {
            int sampleCountInt = int(floor(sampleCount));
            vec4 accumulator = vec4(0.0);
            vec2 dc = destCoord();
            float normalisedValue = length(((dc / size) - 0.5) * 2.0);
            float strength = clamp((normalisedValue), 0.0, 1.0);
            vec2 vector = normalize((dc - (size / 2.0)) / size);
            vec2 velocity = vector * strength * blur;
            vec2 redOffset = -vector * strength * (blur * 1.0);
            vec2 greenOffset = -vector * strength * (blur * 1.5);
            vec2 blueOffset = -vector * strength * (blur * 2.0);
            for (int i=0; i < sampleCountInt; i++) {
                accumulator.r += sample(image, samplerTransform(image, dc + redOffset)).r;
                redOffset -= velocity / sampleCount;
                accumulator.g += sample(image, samplerTransform(image, dc + greenOffset)).g;
                greenOffset -= velocity / sampleCount;
                accumulator.b += sample(image, samplerTransform(image, dc + blueOffset)).b;
                blueOffset -= velocity / sampleCount;
            }
            return vec4(vec3(accumulator / float(sampleCountInt)), 1.0);
        }
""")!

  func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {

    let width = image.extent.width + image.extent.minX*2
    let height = image.extent.height + image.extent.minY*2

    let base = Double(sqrt(pow(width, 2) + pow(height, 2)))
    let radius = base / 40

    let args = [
      image,
      CIVector(
        x: width,
        y: height
      ),
      20,
      radius,
    ] as [Any]

    return Self.kernel.apply(
      extent: image.extent,
      roiCallback: { _, rect in
        rect
      },
      arguments: args
    )!
  }
}

struct DemoFilterView: View {

  let editingStack: EditingStack
  @State var invertToggle: Bool = false
  @State var grayscaleToggle: Bool = false
  @State var motionBlurToggle: Bool = false

  @State var resultImage: ResultImage?

  init(
    editingStack: EditingStack
  ) {
    self.editingStack = editingStack
  }

  var body: some View {
    VStack {

      SwiftUIImagePreviewView(editingStack: editingStack)

      VStack {
        Toggle("Invert", isOn: $invertToggle)
        Toggle("Grayscale", isOn: $grayscaleToggle)
        Toggle("MotionBlur", isOn: $motionBlurToggle)
      }
      .onChange(of: [invertToggle, grayscaleToggle, motionBlurToggle], perform: { _ in
        editingStack.set(effects: {
          $0.set(grayscaleToggle ? DemoGrayscaleFeature() : nil)
          $0.set(invertToggle ? DemoInvertFeature() : nil)
          $0.set(motionBlurToggle ? DemoMotionBlurFeature() : nil)
        })
      })
      .padding()

      Button("Done") {
        try! editingStack.makeRenderer().render { result in
          switch result {
          case let .success(rendered):
            self.resultImage = .init(cgImage: rendered.cgImage)
          case let .failure(error):
            print(error)
          }
        }
      }

    }
    .onAppear {
      editingStack.start()
    }
    .sheet(item: $resultImage) {
      RenderedResultView(result: $0)
    }

  }

}

#Preview("local") {
  DemoFilterView(
    editingStack: Mocks.makeEditingStack(image: Mocks.imageHorizontal())
  )
}

#Preview("remote") {
  DemoFilterView(
    editingStack: EditingStack(
      imageProvider: .init(
        editableRemoteURL: URL(
          string:
            "https://images.unsplash.com/photo-1604456930969-37f67bcd6e1e?ixid=MXwxMjA3fDB8MHxwaG90by1wYWdlfHx8fGVufDB8fHw%3D&ixlib=rb-1.2.1"
        )!
      )
    )
  )
}
