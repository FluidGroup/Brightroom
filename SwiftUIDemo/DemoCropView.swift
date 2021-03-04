//
//  DemoCropView.swift
//  SwiftUIDemo
//
//  Created by Muukii on 2021/03/05.
//  Copyright © 2021 muukii. All rights reserved.
//

import Foundation
import SwiftUI
import PixelEditor
import PixelEngine

struct DemoCropView: View {
  
  let editingStack: EditingStack
    
  var body: some View {
    SwiftUICropView(editingStack: editingStack)
      .onAppear {
        editingStack.start()
      }
  }
  
}
