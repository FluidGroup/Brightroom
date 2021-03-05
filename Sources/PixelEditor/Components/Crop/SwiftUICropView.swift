//
// Copyright (c) 2021 Muukii <muukii.app@gmail.com>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import Foundation
import SwiftUI
import PixelEngine

final class WrapperViewController<BodyView: UIView>: UIViewController {
  
  private let bodyView: BodyView
  
  init(bodyView: BodyView) {
    self.bodyView = bodyView
    super.init(nibName: nil, bundle: nil)
  }
  
  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  public override func viewDidLoad() {
    super.viewDidLoad()
    
    view.addSubview(bodyView)
    AutoLayoutTools.setEdge(bodyView, view)
  }
}

/**
 Still in development
 */
@available(iOS 14, *)
public struct SwiftUICropView: View {
    
  private let editingStack: EditingStack
  private let cropInsideOverlay: AnyView?
  
  public init(
    editingStack: EditingStack,
    cropInsideOverlay: AnyView? = nil
  ) {
    self.editingStack = editingStack
    self.cropInsideOverlay = cropInsideOverlay
  }
  
  public var body: some View {
    _SwiftUICropView(editingStack: editingStack, cropInsideOverlay: cropInsideOverlay)
  }
  
}
/**
 Still in development
 */
@available(iOS 14, *)
struct _SwiftUICropView: UIViewControllerRepresentable {
  
  typealias UIViewControllerType = WrapperViewController<CropView>
      
  private let editingStack: EditingStack
  private let cropInsideOverlay: AnyView?
  
  init(
    editingStack: EditingStack,
    cropInsideOverlay: AnyView? = nil
  ) {
    self.editingStack = editingStack
    self.cropInsideOverlay = cropInsideOverlay
  }
  
  func makeUIViewController(context: Context) -> WrapperViewController<CropView> {
    let view = CropView(editingStack: editingStack)
    
    let controller = WrapperViewController.init(bodyView: view)
    
    if let cropInsideOverlay = cropInsideOverlay {
      
      let hosting = UIHostingController.init(rootView: cropInsideOverlay)
      
      hosting.view.backgroundColor = .clear
      hosting.view.preservesSuperviewLayoutMargins = false
      
      view.setCropInsideOverlay(CropView.SwiftUICropInsideOverlay(controller: hosting))
      
      controller.addChild(hosting)
      hosting.didMove(toParent: controller)
    }
        
    return controller
  }
  
  func updateUIViewController(_ uiViewController: WrapperViewController<CropView>, context: Context) {
    
  }
    
}
