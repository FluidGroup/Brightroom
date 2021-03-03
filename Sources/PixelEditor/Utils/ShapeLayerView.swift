
final class ShapeLayerView: PixelEditorCodeBasedView {
  override class var layerClass: AnyClass {
    return CAShapeLayer.self
  }
    
  override var layer: CAShapeLayer {
    return super.layer as! CAShapeLayer
  }
    
  override func action(for layer: CALayer, forKey event: String) -> CAAction? {
    
    if UIView.inheritedAnimationDuration > 0, event == "path" {
      let animation = CABasicAnimation(keyPath: "path")
      animation.duration = UIView.inheritedAnimationDuration
      return animation
    }
    
    let action = super.action(for: layer, forKey: event)
    return action
  }
  
  override init(
    frame: CGRect
  ) {
    super.init(frame: frame)
    self.backgroundColor = .clear
    self.layer.contentsScale = UIScreen.main.scale
    self.layer.allowsEdgeAntialiasing = true
    self.layer.lineWidth = 0
  }
}
