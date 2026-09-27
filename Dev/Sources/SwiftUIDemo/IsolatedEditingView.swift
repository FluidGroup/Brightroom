import BrightroomEngine
import BrightroomUI
import SwiftUI
import StateGraph

struct IsolatedEditinView: View {
  @State private var store = DemoDocumentStore(
    image: Mocks.makeSourceImage(image: Mocks.imageHorizontal())
  )
  @State private var fullScreenView: FullscreenIdentifiableView?

  var body: some View {
    Form.init {
      Button("Crop") {
        fullScreenView = .init(showsDismissButton: false) {
          DemoImageEditor(store: store)
        }
      }
    }
    .navigationTitle("Isolated-Editing")
    .fullScreenCover(
      item: $fullScreenView,
      onDismiss: {},
      content: {
        $0
      }
    )
  }
}
