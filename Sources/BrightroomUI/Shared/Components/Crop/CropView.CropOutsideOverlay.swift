//
//  CropView.CropOutsideOverlay.swift
//  PixelEditor
//
//  Created by Muukii on 2021/03/03.
//  Copyright © 2021 muukii. All rights reserved.
//

import UIKit
import SwiftUI

extension CropView {

  class CropOutsideOverlayBase: _PixelEditorCodeBasedView {

    func didBeginAdjustment(kind: CropView.AdjustmentKind) {
      
    }
    
    func didEndAdjustment(kind: CropView.AdjustmentKind) {
      
    }
    
  }
  
  final class CropOutsideOverlayBlurredView: CropOutsideOverlayBase {
    
    private let effectView: UIVisualEffectView
    private let dimmingView: UIView
        
    private var currentAnimator: UIViewPropertyAnimator?
    
    init(
      blurEffect: UIBlurEffect = UIBlurEffect(style: .dark),
      dimmingColor: UIColor = .init(white: 0, alpha: 0.6)
    ) {
      
      self.effectView = UIVisualEffectView(effect: blurEffect)
      self.dimmingView = UIView()&>.do {
        $0.backgroundColor = dimmingColor
      }
      
      super.init(frame: .zero)
      
      addSubview(dimmingView)
      addSubview(effectView)
                
      AutoLayoutTools.setEdge(dimmingView, self)
      AutoLayoutTools.setEdge(effectView, self)
    }
    
    override func didBeginAdjustment(kind: CropView.AdjustmentKind) {
      
      if kind == .guide {
        
        currentAnimator?.stopAnimation(true)
        currentAnimator = UIViewPropertyAnimator(duration: 0.6, dampingRatio: 1) { [weak self] in
          self?.effectView.alpha = 0
        }&>.do {
          $0.startAnimation()
        }
      }
    }
    
    override func didEndAdjustment(kind: CropView.AdjustmentKind) {
      
      if kind == .guide {
        currentAnimator?.stopAnimation(true)
        currentAnimator = UIViewPropertyAnimator(duration: 0.6, dampingRatio: 1) { [weak self] in
          self?.effectView.alpha = 1
        }&>.do {
          $0.startAnimation(afterDelay: 1)
        }
      }
    }
  }
  
  @available(iOS 14, *)
  class SwiftUICropOutsideOverlay<Content: View>: CropOutsideOverlayBase {

    private let controller: UIHostingController<Container>
    private let proxy: Proxy

    init(@ViewBuilder content: @escaping (CropView.AdjustmentKind?) -> Content) {

      self.proxy = .init()
      self.controller = .init(rootView: Container(proxy: proxy, content: content))

      controller.view.backgroundColor = .clear
      controller.view.preservesSuperviewLayoutMargins = false

      super.init(frame: .zero)
      
      addSubview(controller.view)
      AutoLayoutTools.setEdge(controller.view, self)
    }

    override func didBeginAdjustment(kind: CropView.AdjustmentKind) {
      proxy.activeKind = kind
    }

    override func didEndAdjustment(kind: CropView.AdjustmentKind) {
      proxy.activeKind = nil
    }

    private final class Proxy: ObservableObject {

      @Published var activeKind: CropView.AdjustmentKind?

    }

    private struct Container: View {

      @ObservedObject var proxy: Proxy

      private let content: (CropView.AdjustmentKind?) -> Content

      init(
        proxy: Proxy,
        content: @escaping (CropView.AdjustmentKind?) -> Content
      ) {
        self.content = content
        self.proxy = proxy
      }

      var body: some View {
        content(proxy.activeKind)
      }
    }

  }

}
