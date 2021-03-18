
import PixelEngine
import SwiftUI

struct IsolatedEditinView: View {
//  @StateObject var editingStack = Mocks.makeEditingStack(image: Mocks.imageHorizontal())
  @StateObject var editingStack = Mocks.makeEditingStack(fileURL:
    Bundle.main.path(
      forResource: "gaku",
      ofType: "jpeg"
    ).map {
      URL(fileURLWithPath: $0)
    }!)
  @State private var fullScreenView: FullscreenIdentifiableView?

  var body: some View {
    Form {
      Button("Crop") {
        fullScreenView = .init { CropViewControllerWrapper(
          editingStack: editingStack,
          onCompleted: {}
        ) }
      }

      Button("Custom Crop") {
        fullScreenView = .init { DemoCropView(editingStack: editingStack) }
      }

      Button("Blur Mask") {
        fullScreenView = .init { MaskingViewWrapper(editingStack: editingStack) }
      }
    }
    .navigationTitle("Isolated-Editing")
    .fullScreenCover(
      item: $fullScreenView,
      onDismiss: {}, content: {
        $0
      }
    )
  }
}
