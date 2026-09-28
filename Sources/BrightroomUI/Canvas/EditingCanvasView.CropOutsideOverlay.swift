//
//  EditingCanvasView.CropOutsideOverlay.swift
//  BrightroomUI
//
//  Created by Muukii on 2021/03/03.
//  Copyright © 2021 muukii. All rights reserved.
//

import UIKit
import SwiftUI

extension EditingCanvasView {

  class CropOutsideOverlayBase: CodeBasedView {

    func didBeginInteraction(_ interaction: CropInteraction) {
      
    }
    
    func didEndInteraction(_ interaction: CropInteraction) {
      
    }
    
  }
  
  /// Blurs the area outside the crop, fading the blur out during guide or scroll adjustments.
  final class CropOutsideOverlayBlurredView: CropOutsideOverlayBase {
    
    private let effectView: UIVisualEffectView
    private let dimmingView: UIView
        
    private var currentAnimator: UIViewPropertyAnimator?
    
    init(
      blurEffect: UIBlurEffect = UIBlurEffect(style: .dark),
      dimmingColor: UIColor = .init(white: 0, alpha: 0.6)
    ) {
      
      self.effectView = UIVisualEffectView(effect: blurEffect)
      let dimmingView = UIView()
      dimmingView.backgroundColor = dimmingColor
      self.dimmingView = dimmingView
      
      super.init(frame: .zero)
      
      addSubview(dimmingView)
      addSubview(effectView)
                
      AutoLayoutTools.setEdge(dimmingView, self)
      AutoLayoutTools.setEdge(effectView, self)
    }
    
    override func didBeginInteraction(_ interaction: CropInteraction) {
      currentAnimator?.stopAnimation(true)
      let animator = UIViewPropertyAnimator(duration: 0.6, dampingRatio: 1) { [weak self] in
        self?.effectView.alpha = 0
      }
      animator.startAnimation()
      currentAnimator = animator
    }

    override func didEndInteraction(_ interaction: CropInteraction) {
      currentAnimator?.stopAnimation(true)
      let animator = UIViewPropertyAnimator(duration: 0.6, dampingRatio: 1) { [weak self] in
        self?.effectView.alpha = 1
      }
      animator.startAnimation(afterDelay: 1)
      currentAnimator = animator
    }
  }
  
  class SwiftUICropOutsideOverlay<Content: View>: CropOutsideOverlayBase {

    private let controller: UIHostingController<Container>
    private let proxy: Proxy

    init(@ViewBuilder content: @escaping (CropInteraction?) -> Content) {

      self.proxy = .init()
      self.controller = .init(rootView: Container(proxy: proxy, content: content))

      controller.view.backgroundColor = .clear
      controller.view.preservesSuperviewLayoutMargins = false

      super.init(frame: .zero)
      
      addSubview(controller.view)
      AutoLayoutTools.setEdge(controller.view, self)
    }

    override func didBeginInteraction(_ interaction: CropInteraction) {
      proxy.activeInteraction = interaction
    }

    override func didEndInteraction(_ interaction: CropInteraction) {
      proxy.activeInteraction = nil
    }

    private final class Proxy: ObservableObject {

      @Published var activeInteraction: CropInteraction?

    }

    private struct Container: View {

      @ObservedObject var proxy: Proxy

      private let content: (CropInteraction?) -> Content

      init(
        proxy: Proxy,
        content: @escaping (CropInteraction?) -> Content
      ) {
        self.content = content
        self.proxy = proxy
      }

      var body: some View {
        content(proxy.activeInteraction)
      }
    }

  }

}
