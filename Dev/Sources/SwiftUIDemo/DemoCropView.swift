//
//  DemoCropView.swift
//  SwiftUIDemo
//
//  Created by Muukii on 2021/03/05.
//  Copyright © 2021 muukii. All rights reserved.
//

import BrightroomEngine
import BrightroomUI
import BrightroomUIPhotosCrop
import SwiftUI
import UIKit

struct DemoCropView: View {

  @StateObject var editingStack: EditingStack
  @State var resultImage: ResultImage?


  init(
    editingStack: @escaping () -> EditingStack
  ) {
    self._editingStack = .init(wrappedValue: editingStack())
  }

  var body: some View {
    VStack {
      PhotosCropRotating(editingStack: { editingStack })
      Button("Done") {
        let image = try! editingStack.makeRenderer().render().cgImage
        self.resultImage = .init(cgImage: image)
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

#Preview {
  DemoCropView(
    editingStack: { Mocks.makeEditingStack(image: Mocks.imageHorizontal()) }
  )
}

#Preview {
  Text("")
    .onAppear {

      let uiView = UIView(frame: .init(origin: .zero, size: .init(width: 100, height: 200)))
      print(uiView.frame)

      uiView.transform = .init(rotationAngle: Angle(degrees: 10).radians)
      print(uiView.transform)

      print(uiView.frame, uiView.bounds)
    }
}
