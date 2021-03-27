//
//  MaskingViewWrapper.swift
//  SwiftUIDemo
//
//  Created by Muukii on 2021/03/16.
//  Copyright © 2021 muukii. All rights reserved.
//

import SwiftUI

import BrightroomEngine
import BrightroomUI

struct MaskingViewWrapper: UIViewRepresentable {
  
  typealias UIViewType = BlurryMaskingView
  
  private let editingStack: EditingStack
  
  init(editingStack: EditingStack) {
    self.editingStack = editingStack
  }

  func makeUIView(context: Context) -> BlurryMaskingView {
    let view = UIViewType.init(editingStack: editingStack)    
    return view
  }
  
  func updateUIView(_ uiView: BlurryMaskingView, context: Context) {

  }
    
}
