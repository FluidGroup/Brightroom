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

import BrightroomEngine

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
    var perspectiveCorrection: EditingCrop.PerspectiveCorrection = .identity {
      didSet {
        guard perspectiveCorrection != oldValue else {
          return
        }

        setNeedsLayout()
      }
    }

    var overlay: UIView? {
      didSet {
        oldValue?.removeFromSuperview()
        if let overlay {
          overlay.layer.anchorPoint = .zero
          addSubview(overlay)
        }
      }
    }

    override init(frame: CGRect) {
      self.imageView = _ImageView()
      super.init(frame: frame)

      imageView.layer.anchorPoint = .zero
      addSubview(imageView)
    }
    
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }
    
    override func layoutSubviews() {
      super.layoutSubviews()
      layoutPerspectiveContent(imageView)
      if let overlay {
        layoutPerspectiveContent(overlay)
      }
      #if DEBUG
      layer.addSublayer(debugShapeLayer)
      debugShapeLayer.frame = bounds
      #endif
    }

    private func layoutPerspectiveContent(_ view: UIView) {
      view.layer.transform = CATransform3DIdentity
      view.bounds = .init(origin: .zero, size: bounds.size)
      view.layer.position = bounds.origin
      view.layer.transform = perspectiveCorrection.displayLayerTransform(in: view.bounds)
    }

    func _debug_setPath(path: UIBezierPath) {
      #if DEBUG
      debugShapeLayer.path = path.cgPath
      #endif
    }

  }

}

private extension EditingCrop.PerspectiveCorrection {

  func displayLayerTransform(in bounds: CGRect) -> CATransform3D {
    guard isIdentity == false, bounds.isEmpty == false else {
      return CATransform3DIdentity
    }

    let source = [
      CGPoint(x: bounds.minX, y: bounds.minY),
      CGPoint(x: bounds.maxX, y: bounds.minY),
      CGPoint(x: bounds.maxX, y: bounds.maxY),
      CGPoint(x: bounds.minX, y: bounds.maxY),
    ]
    let targetQuadrilateral = displayTargetQuadrilateral(in: bounds)
    let target = [
      targetQuadrilateral.topLeft,
      targetQuadrilateral.topRight,
      targetQuadrilateral.bottomRight,
      targetQuadrilateral.bottomLeft,
    ]

    guard let coefficients = ProjectiveTransformCoefficients(source: source, target: target) else {
      return CATransform3DIdentity
    }

    return coefficients.caTransform3D
  }
}

private struct ProjectiveTransformCoefficients {

  var a: CGFloat
  var b: CGFloat
  var c: CGFloat
  var d: CGFloat
  var e: CGFloat
  var f: CGFloat
  var g: CGFloat
  var h: CGFloat

  var caTransform3D: CATransform3D {
    .init(
      m11: a, m12: d, m13: 0, m14: g,
      m21: b, m22: e, m23: 0, m24: h,
      m31: 0, m32: 0, m33: 1, m34: 0,
      m41: c, m42: f, m43: 0, m44: 1
    )
  }

  init?(
    source: [CGPoint],
    target: [CGPoint]
  ) {
    guard source.count == 4, target.count == 4 else {
      return nil
    }

    var rows = Array(
      repeating: Array(repeating: CGFloat.zero, count: 9),
      count: 8
    )

    for index in 0..<4 {
      let sourcePoint = source[index]
      let targetPoint = target[index]
      let x = sourcePoint.x
      let y = sourcePoint.y
      let u = targetPoint.x
      let v = targetPoint.y
      let row = index * 2

      rows[row] = [
        x, y, 1,
        0, 0, 0,
        -u * x, -u * y,
        u,
      ]
      rows[row + 1] = [
        0, 0, 0,
        x, y, 1,
        -v * x, -v * y,
        v,
      ]
    }

    guard let solution = Self.solve(rows) else {
      return nil
    }

    self.a = solution[0]
    self.b = solution[1]
    self.c = solution[2]
    self.d = solution[3]
    self.e = solution[4]
    self.f = solution[5]
    self.g = solution[6]
    self.h = solution[7]
  }

  private static func solve(_ augmentedRows: [[CGFloat]]) -> [CGFloat]? {
    var rows = augmentedRows
    let count = 8
    let epsilon: CGFloat = 1e-10

    for column in 0..<count {
      var pivotRow = column
      var pivotMagnitude = abs(rows[column][column])

      for candidateRow in (column + 1)..<count {
        let magnitude = abs(rows[candidateRow][column])
        if magnitude > pivotMagnitude {
          pivotMagnitude = magnitude
          pivotRow = candidateRow
        }
      }

      guard pivotMagnitude > epsilon else {
        return nil
      }

      if pivotRow != column {
        rows.swapAt(pivotRow, column)
      }

      let pivot = rows[column][column]
      for index in column...count {
        rows[column][index] /= pivot
      }

      for row in 0..<count where row != column {
        let factor = rows[row][column]
        guard abs(factor) > epsilon else {
          continue
        }

        for index in column...count {
          rows[row][index] -= factor * rows[column][index]
        }
      }
    }

    return rows.map { $0[count] }
  }
}
