//
//  DemoCropView.swift
//  SwiftUIDemo
//
//  Created by Muukii on 2021/03/05.
//  Copyright © 2021 muukii. All rights reserved.
//

import BrightroomUI
import BrightroomEngine
import SwiftUI
import UIKit

struct DemoCropView: View {

  let editingStack: EditingStack

  @State var rotation: EditingCrop.Rotation?
  @State var adjustmentAngle: EditingCrop.AdjustmentAngle = .zero

  var body: some View {
    VStack {
      ZStack {
        Color.black
          .ignoresSafeArea()

        VStack {
          SwiftUICropView(
            editingStack: editingStack,
            cropInsideOverlay: .init(
              /**
               Here is how to create a customized overlay view.
               */
              VStack {
                Circle()
                  .foregroundColor(.white)
                  .frame(width: 50, height: 50, alignment: .center)
              })
          )
          .rotation(rotation)
          .adjustmentAngle(adjustmentAngle)
          .clipped()

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
              self.adjustmentAngle -= .degrees(10)
            }
            Button("+ 10") {
              self.adjustmentAngle += .degrees(10)
            }
          }
        }
      }
      Button("Done") {
        let image = try! editingStack.makeRenderer().render().swiftUIImage
        print(image)
      }
    }
    .onAppear {
      editingStack.start()
    }
  }
}

#Preview {
  DemoCropView(editingStack: Mocks.makeEditingStack(image: Mocks.imageHorizontal()))
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


