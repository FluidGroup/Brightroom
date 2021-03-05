//
//  DemoCropView.swift
//  SwiftUIDemo
//
//  Created by Muukii on 2021/03/05.
//  Copyright © 2021 muukii. All rights reserved.
//

import Foundation
import PixelEditor
import PixelEngine
import SwiftUI

struct DemoCropView: View {
  let editingStack: EditingStack

  var body: some View {
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
      .onAppear {
        editingStack.start()
      }
    }
  }
}
