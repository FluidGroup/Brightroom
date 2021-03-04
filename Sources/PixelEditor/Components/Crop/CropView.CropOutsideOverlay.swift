//
//  CropView.CropOutsideOverlay.swift
//  PixelEditor
//
//  Created by Muukii on 2021/03/03.
//  Copyright © 2021 muukii. All rights reserved.
//

import Foundation

extension CropView {

  open class CropOutsideOverlayBase: PixelEditorCodeBasedView {
    
    open func didBeginAdjustment() {
      
    }
    
    open func didEndAdjustment() {
      
    }
  }
  
  public final class CropOutsideOverlayBlurredView: CropOutsideOverlayBase {
    
    private let effectView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let dimmingView = UIView()
        
    private var currentAnimator: UIViewPropertyAnimator?

    
    init() {
      
      super.init(frame: .zero)
      
      addSubview(dimmingView)
      addSubview(effectView)
      
      dimmingView.backgroundColor = .init(white: 0, alpha: 0.6)
          
      AutoLayoutTools.setEdge(dimmingView, self)
      AutoLayoutTools.setEdge(effectView, self)
    }
    
    public override func didBeginAdjustment() {
      currentAnimator?.stopAnimation(true)
      currentAnimator = UIViewPropertyAnimator(duration: 0.6, dampingRatio: 1) { [weak self] in
        self?.effectView.alpha = 0
      }&>.do {
        $0.startAnimation()
      }
    }
    
    public override func didEndAdjustment() {
      currentAnimator?.stopAnimation(true)
      currentAnimator = UIViewPropertyAnimator(duration: 0.6, dampingRatio: 1) { [weak self] in
        self?.effectView.alpha = 1
      }&>.do {
        $0.startAnimation(afterDelay: 1)
      }
    }
  }
  
}
