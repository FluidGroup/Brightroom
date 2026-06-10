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

import UIKit

extension CropView {
  
  /**
   Internal UIScrollView's subclass.
   */
  final class _CropScrollView: UIScrollView {
    override init(frame: CGRect) {
      super.init(frame: frame)
      
      initialize()
    }
    
    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
      fatalError()
    }
    
    private func initialize() {
      if #available(iOS 11.0, *) {
        contentInsetAdjustmentBehavior = .never        
      } else {
        // Fallback on earlier versions
      }
      insetsLayoutMarginsFromSafeArea = false
      showsVerticalScrollIndicator = false
      showsHorizontalScrollIndicator = false
      bouncesZoom = true
      decelerationRate = UIScrollView.DecelerationRate.fast
      clipsToBounds = false
      alwaysBounceVertical = true
      alwaysBounceHorizontal = true
      scrollsToTop = false
    }
  }

  final class ImagePlatterView: UIView {

    #if DEBUG
    private let debugShapeLayer: CAShapeLayer = {
      let layer = CAShapeLayer()
      layer.strokeColor = UIColor.systemBlue.cgColor
      layer.lineWidth = 2
      layer.fillColor = nil
      return layer
    }()
    #endif

    var image: UIImage? {
      get {
        imageView.image
      }
      set {
        imageView.image = newValue
      }
    }

    let imageView: UIImageView

    var overlay: UIView? {
      didSet {
        oldValue?.removeFromSuperview()
        if let overlay {
          addSubview(overlay)
        }
      }
    }

    override init(frame: CGRect) {
      self.imageView = _ImageView()
      super.init(frame: frame)

      addSubview(imageView)
    }
    
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }
    
    override func layoutSubviews() {
      super.layoutSubviews()
      imageView.frame = bounds
      overlay?.frame = bounds
      #if DEBUG
      layer.addSublayer(debugShapeLayer)
      debugShapeLayer.frame = bounds
      #endif
    }

    func _debug_setPath(path: UIBezierPath) {
      #if DEBUG
      debugShapeLayer.path = path.cgPath
      #endif
    }

  }

}
