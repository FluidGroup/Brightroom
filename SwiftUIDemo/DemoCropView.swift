//
//  DemoCropView.swift
//  SwiftUIDemo
//
//  Created by Muukii on 2021/03/05.
//  Copyright © 2021 muukii. All rights reserved.
//

import UIKit
import PixelEditor
import PixelEngine
import SwiftUI

struct DemoCropView: View {
  let editingStack: EditingStack

  var body: some View {
    VStack {
      ZStack {
        Color.black
          .ignoresSafeArea()
        SwiftUICropView(
          editingStack: editingStack,
          cropInsideOverlay: .init(VStack {
            Circle()
              .foregroundColor(.white)
              .frame(width: 50, height: 50, alignment: .center)
          })
        )
        .clipped()
      }
      Button("Done") {
        let image = editingStack.makeRenderer().render()
        print(image)
      }
    }
    .onAppear {
      editingStack.start()
    }
  }
}
