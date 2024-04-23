//
//  DemoCropView2.swift
//  SwiftUIDemo
//
//  Created by Jinsei Shima on 2024/02/28.
//  Copyright © 2024 muukii. All rights reserved.
//

import BrightroomEngine
import BrightroomUI
import BrightroomUIPhotosCrop
import SwiftUI
import UIKit
import SwiftUISupport

struct DemoCropView2: View {

  @StateObject var editingStack: EditingStack
  @State var resultImage: ResultImage?
  @State var angle: EditingCrop.AdjustmentAngle = .zero
  @State var baselineAngle: EditingCrop.AdjustmentAngle = .zero
  @State var isDragging: Bool = false

  init(
    editingStack: @escaping () -> EditingStack
  ) {
    self._editingStack = .init(wrappedValue: editingStack())
  }

  var body: some View {
    ZStack {

      VStack {

        Spacer()

        SwiftUICropView(
          editingStack: editingStack,
          isGuideInteractionEnabled: false,
          contentInset: .init(top: 20, left: 20, bottom: 20, right: 20),
          cropInsideOverlay: { kind in
            ViewHost(instantiated: CropView.RuleOfThirdsView(lineColor: .white))
              .overlay {
                Rectangle()
                  .fill(kind == nil ? Color.white : Color.white.opacity(0.6))
                  .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                      .blendMode(.destinationOut)
                  }
                  .compositingGroup()
              }
          },
          cropOutsideOverlay: { kind in
            Rectangle()
              .fill(kind == nil ? Color.white : Color.white.opacity(0.6))
          },
          stateHandler: { state in
            state.ifChanged(\.adjustmentKind).do { kind in
              if kind.isEmpty {
                isDragging = false
              } else {
                isDragging = true
              }
            }
          }
        )
        .adjustmentAngle(angle + baselineAngle)
        .croppingAspectRatio(.init(width: 1, height: 1.4))
        .frame(height: 300)
        .clipped()
        .background(Color.gray)
        
        ViewHost(instantiated: ImagePreviewView(editingStack: editingStack))
          .background(Color.black)
          .cornerRadius(24, style: .continuous)
          .padding(.init(top: 20, leading: 20, bottom: 20, trailing: 20))
          .frame(width: 300/1.4, height: 300)

        Spacer()

        HStack {
          Slider(value: $angle.degrees, in: -45.0...45.0, step: 1)
          Button(action: {
            baselineAngle -= .degrees(90)
          }, label: {
            Text("Rotate")
          })
        }
        .disabled(isDragging)
        .padding(24)

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
    .onAppear {
      editingStack.start()
    }
    .sheet(item: $resultImage) {
      RenderedResultView(result: $0)
    }
  }

}

#Preview("local") {
  DemoCropView2(
    editingStack: { Mocks.makeEditingStack(image: Mocks.imageHorizontal()) }
  )
}

#Preview("remote") {
  DemoCropView2(
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
