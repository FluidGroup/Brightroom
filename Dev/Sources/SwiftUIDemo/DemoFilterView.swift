
import BrightroomEngine
import BrightroomUI
import SwiftUI
import SwiftUISupport
import UIKit

struct CustomFilter: Filtering, Equatable, Codable {

  init() {

  }

  func apply(to image: CIImage, sourceImage: CIImage) -> CIImage {
    image
      .applyingFilter("CIColorInvert")
  }

}


struct DemoFilterView: View {

  @StateObject var editingStack: EditingStack
  @State var toggle: Bool = false

  init(
    editingStack: @escaping () -> EditingStack
  ) {
    self._editingStack = .init(wrappedValue: editingStack())
  }

  var body: some View {
    VStack {

      ViewHost(instantiated: ImagePreviewView(editingStack: editingStack))

      Toggle("Invert", isOn: $toggle)
        .onChange(of: toggle) { newValue in
          editingStack.set(filters: {
            if newValue {
              $0.custom["custom"] = CustomFilter().asAny()
            } else {
              $0.custom["custom"] = nil
            }
          })
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
