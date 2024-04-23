import BrightroomEngine
import SwiftUISupport
import BrightroomUI
import SwiftUI

struct DemoMaskingView: View {

  @ObjectEdge var editingStack: EditingStack

  @State var brushSize: CanvasView.BrushSize = .point(30)

  init(editingStack: @escaping () -> EditingStack) {
    self._editingStack = .init(wrappedValue: editingStack())
  }

  var body: some View {
    VStack {
      ZStack {
        ViewHost(instantiated: ImagePreviewView(editingStack: editingStack))
        SwiftUIBlurryMaskingView(editingStack: editingStack)
          .blushSize(brushSize)
          .hideBackdropImageView(true)
      }

      HStack {
        Button(action: {
          brushSize = .point(10)
        }, label: {
          Text("10")
        })
        Button(action: {
          brushSize = .point(30)
        }, label: {
          Text("30")
        })
        Button(action: {
          brushSize = .point(50)
        }, label: {
          Text("50")
        })
      }

    }
  }

}

#Preview {
  DemoMaskingView(
    editingStack: {
      Mocks.makeEditingStack(
        image: Asset.verticalRect.image
      )
    }
  )
}
