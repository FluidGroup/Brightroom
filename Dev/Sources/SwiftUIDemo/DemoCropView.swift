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
    ZStack {

      VStack {
        PhotosCropRotating(editingStack: { editingStack })
//        Button("Done") {
//          let image = try! editingStack.makeRenderer().render().cgImage
//          self.resultImage = .init(cgImage: image)
//        }
      }

      VStack {
        HStack {
          Spacer()
          Button("Done") {
            let image = try! editingStack.makeRenderer().render().cgImage
            self.resultImage = .init(cgImage: image)
          }
          .buttonStyle(.borderedProminent)
          .buttonBorderShape(.capsule)
          .tint(.yellow)
          .foregroundColor(.black)
        }
        Spacer()
      }
      .padding(.horizontal, 30)
      .padding(.vertical, 15)
      .ignoresSafeArea()

    }
//    .safeAreaInset(edge: .top, content: {
//      Button("Done") {
//        let image = try! editingStack.makeRenderer().render().cgImage
//        self.resultImage = .init(cgImage: image)
//      }
//    })

    .onAppear {
      editingStack.start()
    }
    .sheet(item: $resultImage) {
      RenderedResultView(result: $0)
    }
  }

}

#Preview("local") {
  DemoCropView(
    editingStack: { Mocks.makeEditingStack(image: Mocks.imageHorizontal()) }
  )
}

#Preview("remote") {
  DemoCropView(
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
