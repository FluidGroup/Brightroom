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
          .clipped()

          HStack {
            Button("rotate") {
              self.rotation = .angle_180
            }
            Button("- 10") {
              self.rotation = .angle_180
            }
            Button("+ 10") {
              self.rotation = .angle_180
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
