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

  var body: some View {
    VStack {
      ZStack {
        Color.black
          .ignoresSafeArea()
        
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
        .clipped()
      }
      Button("Done") {
        let image = try! editingStack.makeRenderer().render().swiftUIImageDisplayP3
        print(image)
      }
    }
    .onAppear {
      editingStack.start()
    }
  }
}
