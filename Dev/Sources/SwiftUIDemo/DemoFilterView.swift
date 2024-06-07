
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

  let invertFilter: InvertFilter = .init()
  let grayscaleFilter: GrayscaleFilter = .init()

  @StateObject var editingStack: EditingStack
  @State var invertToggle: Bool = false
  @State var grascaleToggle: Bool = false

  init(
    editingStack: @escaping () -> EditingStack
  ) {
    self._editingStack = .init(wrappedValue: editingStack())
  }

  var body: some View {
    VStack {

      ViewHost(instantiated: ImagePreviewView(editingStack: editingStack))

      VStack {
        Toggle("Invert", isOn: $invertToggle)
          .onChange(of: invertToggle) { newValue in
            editingStack.set(filters: {
              $0.additionalFilters = [
                grascaleToggle ? grayscaleFilter.asAny() : nil,
                invertToggle ? invertFilter.asAny() : nil,
              ].compactMap({ $0 })
            })
          }

        Toggle("Grayscale", isOn: $grascaleToggle)
          .onChange(of: grascaleToggle) { newValue in
            editingStack.set(filters: {
              $0.additionalFilters = [
                grascaleToggle ? grayscaleFilter.asAny() : nil,
                invertToggle ? invertFilter.asAny() : nil,
              ].compactMap({ $0 })
            })
          }
      }
      .padding()

    }
    .onAppear {
      editingStack.start()
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
