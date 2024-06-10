
import BrightroomEngine
import BrightroomUI
import SwiftUI
import SwiftUISupport
import UIKit

struct DemoFilterView: View {

  struct InvertFilter: Filtering {
    func apply(to image: CIImage, sourceImage: CIImage) -> CIImage {
      image
        .applyingFilter("CIColorInvert")
    }
  }

  struct GrayscaleFilter: Filtering {
    func apply(to image: CIImage, sourceImage: CIImage) -> CIImage {
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


  class MotionBlurFilter: CIFilter {
      var inputImage: CIImage?
      var inputDirection: CIVector = CIVector(x: 1, y: 0)

      let kernel = CIKernel(source:
          """
          kernel vec4 motionBlur(sampler image, vec2 direction) {
              vec2 dc = destCoord();
              vec4 color = vec4(0.0);
              int samples = 20;
              for (int i = -samples; i <= samples; i++) {
                  vec2 offset = direction * (10 * float(i) / float(samples));
                  color += sample(image, samplerCoord(dc + offset));
              }
              return color / float(samples * 2 + 1);
          }
          """
      )

      override var outputImage: CIImage? {
          guard let inputImage = inputImage, let kernel = kernel else { return nil }
          let arguments = [inputImage, inputDirection] as [Any]
          return kernel.apply(extent: inputImage.extent, roiCallback: { _, rect in rect }, arguments: arguments)
      }
  }

  struct ChromaticAberrationFilter: Filtering {

    let kernel = CIKernel(source: 
"""
    kernel vec4 motionBlur(sampler image, vec2 size, float sampleCount, float start, float blur) {
            int sampleCountInt = int(floor(sampleCount));
            vec4 accumulator = vec4(0.0);
            vec2 dc = destCoord();
            float normalisedValue = length(((dc / size) - 0.5) * 2.0);
            float strength = clamp((normalisedValue - start) * (1.0 / (1.0 - start)), 0.0, 1.0);
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

    func apply(to image: CIImage, sourceImage: CIImage) -> CIImage {

      let args = [image,
                  CIVector(x: image.extent.width, y: image.extent.height),
                  20,
                  0.2,
                  20,
                ] as [Any]

      return kernel.apply(
        extent: image.extent,
        roiCallback: { _, rect in
          rect
        },
        arguments: args
      )!
    }
  }

  let invertFilter: InvertFilter = .init()
  let grayscaleFilter: GrayscaleFilter = .init()
  let chromaticFilter: ChromaticAberrationFilter = .init()

  @StateObject var editingStack: EditingStack
  @State var invertToggle: Bool = false
  @State var grayscaleToggle: Bool = false
  @State var chromaticToggle: Bool = false

  @State var resultImage: ResultImage?

  init(
    editingStack: @escaping () -> EditingStack
  ) {
    self._editingStack = .init(wrappedValue: editingStack())
  }

  var body: some View {
    VStack {

      ViewHost(instantiated: ImagePreviewView(editingStack: editingStack))

      SwiftUICropView(editingStack: editingStack)
        .clipped()

      VStack {
        Toggle("Invert", isOn: $invertToggle)
        Toggle("Grayscale", isOn: $grayscaleToggle)
        Toggle("Chromatic", isOn: $chromaticToggle)
      }
      .onChange(of: [invertToggle, grayscaleToggle, chromaticToggle], perform: { _ in
        editingStack.set(filters: {
          $0.additionalFilters = [
            grayscaleToggle ? grayscaleFilter.asAny() : nil,
            invertToggle ? invertFilter.asAny() : nil,
            chromaticToggle ? chromaticFilter.asAny() : nil,
          ].compactMap({ $0 })
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
    editingStack: { Mocks.makeEditingStack(image: Mocks.imageHorizontal()) }
  )
}

#Preview("remote") {
  DemoFilterView(
    editingStack: {
      EditingStack(
        imageProvider: .init(
          editableRemoteURL: URL(
            string:
              "https://images.unsplash.com/photo-1604456930969-37f67bcd6e1e?ixid=MXwxMjA3fDB8MHxwaG90by1wYWdlfHx8fGVufDB8fHw%3D&ixlib=rb-1.2.1"
          )!
        )
      )
    }
  )
}
