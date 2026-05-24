//
//  EditingCrop+.swift
//  PixelEditor
//
//  Created by Muukii on 2021/03/19.
//  Copyright © 2021 muukii. All rights reserved.
//

import Foundation
import CoreGraphics

import BrightroomEngine

extension EditingCrop {
  func cropDisplayTransform() -> CGAffineTransform {
    let scaleX: CGFloat = flip.contains(.horizontal) ? -1 : 1
    let scaleY: CGFloat = flip.contains(.vertical) ? -1 : 1

    return CGAffineTransform(rotationAngle: aggregatedRotation.radians)
      .concatenating(.init(scaleX: scaleX, y: scaleY))
  }

  func transformedVisibleSize(_ visibleSize: CGSize) -> CGSize {
    let rect = CGRect(origin: .zero, size: visibleSize)
      .applying(cropDisplayTransform())

    return .init(
      width: abs(rect.width),
      height: abs(rect.height)
    )
  }

  func scrollViewContentSize() -> CGSize {
    // Use imageSize for masking view
//    imageSize
    PixelAspectRatio(imageSize).size(byWidth: 1000)
  }

  func scaleForDrawing() -> CGFloat {
    let scaleFromOriginal = Geometry.diagonalRatio(to: scrollViewContentSize(), from: imageSize)

    return scaleFromOriginal
  }

  func calculateZoomScale(visibleSize: CGSize) -> (min: CGFloat, max: CGFloat) {
    
    let coveredSize = projectedContentCoverageRect().size
    guard coveredSize.width > 0, coveredSize.height > 0 else {
      return (min: 1, max: .greatestFiniteMagnitude)
    }

    let minXScale = visibleSize.width / coveredSize.width
    let minYScale = visibleSize.height / coveredSize.height

    /**
     max meaning scale aspect fill
     */
    let minScale = max(minXScale, minYScale)
        
    return (min: minScale, max: .greatestFiniteMagnitude)
  }

  func zoomExtent() -> CGRect {

    let contentSize = scrollViewContentSize()
    let cropExtent = cropExtent

    let scaleFromOriginal = Geometry.diagonalRatio(to: contentSize, from: imageSize)

    let _cropExtent = cropExtent.applying(.init(scaleX: scaleFromOriginal, y: scaleFromOriginal))

    return _cropExtent.fitting(in: perspectiveCoveredContentRect())
  }

  func makeCropExtent(rect: CGRect) -> CGRect {

    let contentSize = scrollViewContentSize()
    let cropExtent = rect

    let scaleFromOriginal = Geometry.diagonalRatio(to: imageSize, from: contentSize)

    return cropExtent.applying(.init(scaleX: scaleFromOriginal, y: scaleFromOriginal))
  }

  func perspectiveCoveredContentRect() -> CGRect {
    let bounds = CGRect(origin: .zero, size: scrollViewContentSize())
    return perspectiveCorrection.axisAlignedCoverageRect(in: bounds)
  }

  func perspectiveCoveredImageRect() -> CGRect {
    let bounds = CGRect(origin: .zero, size: imageSize)
    return perspectiveCorrection.axisAlignedCoverageRect(in: bounds)
  }

  func projectedContentCoverageRect() -> CGRect {
    let bounds = CGRect(origin: .zero, size: scrollViewContentSize())
    let quadrilateral = ProjectedQuadrilateral(
      perspectiveCorrection.displayTargetQuadrilateral(in: bounds)
    )

    return quadrilateral
      .applyingAroundCenter(
        cropDisplayTransform(),
        center: .init(x: bounds.midX, y: bounds.midY)
      )
      .axisAlignedInnerRect()
  }

}

struct ProjectedQuadrilateral {

  var topLeft: CGPoint
  var topRight: CGPoint
  var bottomRight: CGPoint
  var bottomLeft: CGPoint

  init(
    topLeft: CGPoint,
    topRight: CGPoint,
    bottomRight: CGPoint,
    bottomLeft: CGPoint
  ) {
    self.topLeft = topLeft
    self.topRight = topRight
    self.bottomRight = bottomRight
    self.bottomLeft = bottomLeft
  }

  init(_ quadrilateral: EditingCrop.PerspectiveCorrection.Quadrilateral) {
    self.init(
      topLeft: quadrilateral.topLeft,
      topRight: quadrilateral.topRight,
      bottomRight: quadrilateral.bottomRight,
      bottomLeft: quadrilateral.bottomLeft
    )
  }

  var points: [CGPoint] {
    [
      topLeft,
      topRight,
      bottomRight,
      bottomLeft,
    ]
  }

  func applyingAroundCenter(
    _ transform: CGAffineTransform,
    center: CGPoint
  ) -> Self {
    let centeredTransform = CGAffineTransform(translationX: -center.x, y: -center.y)
      .concatenating(transform)
      .concatenating(.init(translationX: center.x, y: center.y))

    return .init(
      topLeft: topLeft.applying(centeredTransform),
      topRight: topRight.applying(centeredTransform),
      bottomRight: bottomRight.applying(centeredTransform),
      bottomLeft: bottomLeft.applying(centeredTransform)
    )
  }

  func axisAlignedInnerRect() -> CGRect {
    let center = CGPoint(
      x: points.reduce(0) { $0 + $1.x } / CGFloat(points.count),
      y: points.reduce(0) { $0 + $1.y } / CGFloat(points.count)
    )

    let constraints = edgeConstraints(containing: center)
    guard constraints.count >= 3 else {
      return .zero
    }

    let epsilon: CGFloat = 1e-6
    var bestHalfSize: CGSize = .zero

    func consider(halfWidth: CGFloat, halfHeight: CGFloat) {
      guard
        halfWidth > epsilon,
        halfHeight > epsilon,
        constraints.allSatisfy({ $0.contains(halfWidth: halfWidth, halfHeight: halfHeight) })
      else {
        return
      }

      if halfWidth * halfHeight > bestHalfSize.width * bestHalfSize.height {
        bestHalfSize = .init(width: halfWidth, height: halfHeight)
      }
    }

    for firstIndex in constraints.indices {
      for secondIndex in constraints.indices where firstIndex < secondIndex {
        let first = constraints[firstIndex]
        let second = constraints[secondIndex]
        let determinant = first.xCoefficient * second.yCoefficient
          - second.xCoefficient * first.yCoefficient

        guard abs(determinant) > epsilon else {
          continue
        }

        let halfWidth = (
          first.margin * second.yCoefficient
            - second.margin * first.yCoefficient
        ) / determinant
        let halfHeight = (
          first.xCoefficient * second.margin
            - second.xCoefficient * first.margin
        ) / determinant

        consider(halfWidth: halfWidth, halfHeight: halfHeight)
      }
    }

    for constraint in constraints
    where constraint.xCoefficient > epsilon && constraint.yCoefficient > epsilon
    {
      consider(
        halfWidth: constraint.margin / (constraint.xCoefficient * 2),
        halfHeight: constraint.margin / (constraint.yCoefficient * 2)
      )
    }

    guard bestHalfSize.width > 0, bestHalfSize.height > 0 else {
      return .zero
    }

    return .init(
      x: center.x - bestHalfSize.width,
      y: center.y - bestHalfSize.height,
      width: bestHalfSize.width * 2,
      height: bestHalfSize.height * 2
    )
  }

  private func edgeConstraints(containing point: CGPoint) -> [EdgeConstraint] {
    let epsilon: CGFloat = 1e-6
    let points = points

    return points.indices.compactMap { index in
      let start = points[index]
      let end = points[(index + 1) % points.count]
      let edge = CGPoint(x: end.x - start.x, y: end.y - start.y)

      var xCoefficient = -edge.y
      var yCoefficient = edge.x
      var constant = edge.y * start.x - edge.x * start.y

      if xCoefficient * point.x + yCoefficient * point.y + constant < 0 {
        xCoefficient = -xCoefficient
        yCoefficient = -yCoefficient
        constant = -constant
      }

      let margin = xCoefficient * point.x + yCoefficient * point.y + constant
      guard margin > epsilon else {
        return nil
      }

      return .init(
        xCoefficient: abs(xCoefficient),
        yCoefficient: abs(yCoefficient),
        margin: margin
      )
    }
  }
}

private struct EdgeConstraint {
  var xCoefficient: CGFloat
  var yCoefficient: CGFloat
  var margin: CGFloat

  func contains(halfWidth: CGFloat, halfHeight: CGFloat) -> Bool {
    let tolerance: CGFloat = 1e-4
    return xCoefficient * halfWidth + yCoefficient * halfHeight <= margin + tolerance
  }
}

private extension CGRect {

  func fitting(in bounds: CGRect) -> CGRect {
    guard bounds.isNull == false, bounds.isEmpty == false else {
      return self
    }

    let width = min(size.width, bounds.width)
    let height = min(size.height, bounds.height)
    let minX = min(max(origin.x, bounds.minX), bounds.maxX - width)
    let minY = min(max(origin.y, bounds.minY), bounds.maxY - height)

    return .init(
      x: minX,
      y: minY,
      width: width,
      height: height
    )
  }
}
