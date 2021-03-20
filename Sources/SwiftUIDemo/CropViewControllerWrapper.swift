//
//  CropViewControllerWrapper.swift
//  SwiftUIDemo
//
//  Created by Muukii on 2021/03/16.
//  Copyright © 2021 muukii. All rights reserved.
//

import SwiftUI

import PixelEditor
import PixelEngine

struct CropViewControllerWrapper: UIViewControllerRepresentable {
  typealias UIViewControllerType = CropViewController
  
  private let editingStack: EditingStack
  private let onCompleted: () -> Void
  
  init(editingStack: EditingStack, onCompleted: @escaping () -> Void) {
    self.editingStack = editingStack
    self.onCompleted = onCompleted
    editingStack.start()
  }
  
  func makeUIViewController(context: Context) -> CropViewController {
    let cropViewController = CropViewController(editingStack: editingStack)
    cropViewController.handlers.didFinish = onCompleted
    return cropViewController
  }
  
  func updateUIViewController(_ uiViewController: CropViewController, context: Context) {}
}
