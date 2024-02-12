//
//  DemoCropView.swift
//  SwiftUIDemo
//
//  Created by Muukii on 2021/03/05.
//  Copyright © 2021 muukii. All rights reserved.
//

import BrightroomEngine
import BrightroomUI
import SwiftUI
import UIKit

struct DemoCropView: View {

 @ObjectEdge var editingStack: EditingStack

  @State var rotation: EditingCrop.Rotation?
  @State var adjustmentAngle: EditingCrop.AdjustmentAngle?
  @State var croppingAspectRatio: PixelAspectRatio?

  @State var resultImage: ResultImage?

  init(
    editingStack: @escaping () -> EditingStack
  ) {
    self._editingStack = .init(wrappedValue: editingStack())
  }

  var body: some View {
    VStack {
      ZStack {
        Color.black
          .ignoresSafeArea()

        VStack {

          HStack {
            Button(action: {

              if self.rotation == nil {
                self.rotation = .angle_0
                self.rotation = self.rotation!.next()
              } else {
                self.rotation = self.rotation!.next()
              }

            }, label: {
              Image(systemName: "rotate.left")
            })

            Button(action: {}, label: {
              Image(systemName: "aspectratio")
            })
          }

          SwiftUICropView(
            editingStack: editingStack
          )
          .rotation(rotation)
          .adjustmentAngle(adjustmentAngle)
          .croppingAspectRatio(croppingAspectRatio)
          .clipped()

          VStack {

            HStack(spacing: 18) {

              Button {

              } label: {
                ZStack {
                  RoundedRectangle(cornerRadius: 2)
                    .stroke(style: .init(lineWidth: 5))
                    .fill(Color(white: 0.5, opacity: 1))

                  RoundedRectangle(cornerRadius: 2)
                    .fill(Color(white: 0.3, opacity: 1))

                  Image(systemName: "checkmark")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 12)
                    .foregroundStyle(Color.black)
                }
                .tint(.white)
                .frame(width: 18, height: 28)
              }

              Button {

              } label: {
                ZStack {
                  RoundedRectangle(cornerRadius: 2)
                    .stroke(style: .init(lineWidth: 5))
                    .fill(Color(white: 0.5, opacity: 1))

                  RoundedRectangle(cornerRadius: 2)
                    .fill(Color(white: 0.3, opacity: 1))

                  Image(systemName: "checkmark")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 12)
                    .foregroundStyle(Color.black)
                }
                .tint(.white)
                .frame(width: 28, height: 18)
              }
            }

            HStack {
              Button("16:9") {
                self.croppingAspectRatio = .init(width: 16, height: 9)
              }

              Button("Freeform") {
                self.croppingAspectRatio = nil
              }
            }
            HStack {
              Button("0") {
                self.rotation = .angle_0
              }
              Button("90") {
                self.rotation = .angle_90
              }
              Button("180") {
                self.rotation = .angle_180
              }
              Button("270") {
                self.rotation = .angle_270
              }
              Button("- 10") {
                if self.adjustmentAngle == nil {
                  self.adjustmentAngle = .zero
                }
                self.adjustmentAngle! -= .degrees(10)
              }
              Button("+ 10") {
                if self.adjustmentAngle == nil {
                  self.adjustmentAngle = .zero
                }
                self.adjustmentAngle! += .degrees(10)
              }
            }
          }
        }
      }
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
