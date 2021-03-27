//
//  CropView.CropOutsideOverlay.swift
//  PixelEditor
//
//  Created by Muukii on 2021/03/03.
//  Copyright © 2021 muukii. All rights reserved.
//

import UIKit

extension CropView {

  open class CropOutsideOverlayBase: PixelEditorCodeBasedView {
    
    open func didBeginAdjustment(kind: CropView.State.AdjustmentKind) {
      
    }
    
    open func didEndAdjustment(kind: CropView.State.AdjustmentKind) {
      
    }
    
  }
  
  public final class CropOutsideOverlayBlurredView: CropOutsideOverlayBase {
    
    private let effectView: UIVisualEffectView
    private let dimmingView: UIView
        
    private var currentAnimator: UIViewPropertyAnimator?
    
    public init(
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
    
    public override func didBeginAdjustment(kind: CropView.State.AdjustmentKind) {
      
      if kind == .guide {
        
        currentAnimator?.stopAnimation(true)
        currentAnimator = UIViewPropertyAnimator(duration: 0.6, dampingRatio: 1) { [weak self] in
          self?.effectView.alpha = 0
        }&>.do {
          $0.startAnimation()
        }
      }
    }
    
    public override func didEndAdjustment(kind: CropView.State.AdjustmentKind) {
      
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
  
}
