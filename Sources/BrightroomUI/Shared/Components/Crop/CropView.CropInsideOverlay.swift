//
//  CropView.GuideOverlays.swift
//  PixelEditor
//
//  Created by Muukii on 2021/03/03.
//  Copyright © 2021 muukii. All rights reserved.
//

import SwiftUI
import UIKit

/// https://havecamerawilltravel.com/lightroom/crop-overlays/
extension CropView {
  public final class CropOverlayHandlesView: PixelEditorCodeBasedView {

    public let edgeShapeLayer = UIView()

    private let cornerTopLeftHorizontalShapeLayer = UIView()
    private let cornerTopLeftVerticalShapeLayer = UIView()

    private let cornerTopRightHorizontalShapeLayer = UIView()
    private let cornerTopRightVerticalShapeLayer = UIView()

    private let cornerBottomLeftHorizontalShapeLayer = UIView()
    private let cornerBottomLeftVerticalShapeLayer = UIView()

    private let cornerBottomRightHorizontalShapeLayer = UIView()
    private let cornerBottomRightVerticalShapeLayer = UIView()

    public init() {
      super.init(frame: .zero)

      isUserInteractionEnabled = false

      edgeShapeLayer.accessibilityIdentifier = "Edge"
      addSubview(edgeShapeLayer)
      [
        cornerTopLeftHorizontalShapeLayer,
        cornerTopLeftVerticalShapeLayer,
        cornerTopRightHorizontalShapeLayer,
        cornerTopRightVerticalShapeLayer,
        cornerBottomLeftHorizontalShapeLayer,
        cornerBottomLeftVerticalShapeLayer,
        cornerBottomRightHorizontalShapeLayer,
        cornerBottomRightVerticalShapeLayer,
      ].forEach {
        addSubview($0)
        $0.backgroundColor = UIColor.white
      }
    }

    override public func layoutSubviews() {
      super.layoutSubviews()

      edgeShapeLayer&>.do {
        $0.frame = bounds.insetBy(dx: -1, dy: -1)
        $0.layer.borderWidth = 1
        $0.layer.borderColor = UIColor.white.cgColor
      }

      do {

        let lineWidth: CGFloat = 3
        let lineLength: CGFloat = 20

        do {
          cornerTopLeftHorizontalShapeLayer.frame = .init(
            origin: .init(x: -lineWidth, y: -lineWidth),
            size: .init(width: lineLength, height: lineWidth)
          )
          cornerTopLeftVerticalShapeLayer.frame = .init(
            origin: .init(x: -lineWidth, y: -lineWidth),
            size: .init(width: lineWidth, height: lineLength)
          )
        }

        do {
          cornerTopRightHorizontalShapeLayer.frame = .init(
            origin: .init(x: bounds.maxX - lineLength + lineWidth, y: -lineWidth),
            size: .init(width: lineLength, height: lineWidth)
          )
          cornerTopRightVerticalShapeLayer.frame = .init(
            origin: .init(x: bounds.maxX, y: -lineWidth),
            size: .init(width: lineWidth, height: lineLength)
          )
        }

        do {
          cornerBottomRightHorizontalShapeLayer.frame = .init(
            origin: .init(x: bounds.maxX - lineLength + lineWidth, y: bounds.maxY),
            size: .init(width: lineLength, height: lineWidth)
          )
          cornerBottomRightVerticalShapeLayer.frame = .init(
            origin: .init(x: bounds.maxX, y: bounds.maxY - lineLength + lineWidth),
            size: .init(width: lineWidth, height: lineLength)
          )
        }

        do {
          cornerBottomLeftHorizontalShapeLayer.frame = .init(
            origin: .init(x: -lineWidth, y: bounds.maxY),
            size: .init(width: lineLength, height: lineWidth)
          )
          cornerBottomLeftVerticalShapeLayer.frame = .init(
            origin: .init(x: -lineWidth, y: bounds.maxY - lineLength + lineWidth),
            size: .init(width: lineWidth, height: lineLength)
          )
        }

      }

    }
  }

  open class CropInsideOverlayBase: PixelEditorCodeBasedView {

    public init() {
      super.init(frame: .zero)
    }

    open func didBeginAdjustment(kind: CropView.State.AdjustmentKind) {

    }

    open func didEndAdjustment(kind: CropView.State.AdjustmentKind) {

    }

  }

  @available(iOS 14, *)
  open class SwiftUICropInsideOverlay<Content: View>: CropInsideOverlayBase {

    private let controller: UIHostingController<Container>
    private let proxy: Proxy

    public init(@ViewBuilder content: @escaping (CropView.State.AdjustmentKind?) -> Content) {
      
      self.proxy = .init()
      self.controller = .init(rootView: Container(proxy: proxy, content: content))

      controller.view.backgroundColor = .clear
      controller.view.preservesSuperviewLayoutMargins = false

      super.init()
      addSubview(controller.view)
      AutoLayoutTools.setEdge(controller.view, self)
    }

    open override func didBeginAdjustment(kind: CropView.State.AdjustmentKind) {
      proxy.activeKind = kind
    }

    open override func didEndAdjustment(kind: CropView.State.AdjustmentKind) {
      proxy.activeKind = nil
    }

    private final class Proxy: ObservableObject {

      @Published var activeKind: CropView.State.AdjustmentKind?

    }

    private struct Container: View {

      @ObservedObject var proxy: Proxy

      private let content: (CropView.State.AdjustmentKind?) -> Content

      public init(
        proxy: Proxy,
        content: @escaping (CropView.State.AdjustmentKind?) -> Content
      ) {
        self.content = content
        self.proxy = proxy
      }

      var body: some View {
        content(proxy.activeKind)
      }
    }

  }

  public final class RuleOfThirdsView: PixelEditorCodeBasedView {

    private let verticalLine1 = UIView()
    private let verticalLine2 = UIView()

    private let horizontalLine1 = UIView()
    private let horizontalLine2 = UIView()

    public init(lineColor: UIColor = UIColor(white: 1, alpha: 0.3)) {
      super.init(frame: .zero)

      isUserInteractionEnabled = false

      lines()
        .forEach {
          addSubview($0)
          $0.backgroundColor = lineColor
        }

    }

    private func lines() -> [UIView] {
      [
        verticalLine1,
        verticalLine2,
        horizontalLine1,
        horizontalLine2,
      ]
    }

    public override func layoutSubviews() {

      super.layoutSubviews()

      let width = (bounds.width / 3)
      let height = (bounds.height / 3)

      do {

        verticalLine1.frame = .init(
          origin: .init(x: width, y: 0),
          size: .init(width: 1, height: bounds.height)
        )

        verticalLine2.frame = .init(
          origin: .init(x: width * 2, y: 0),
          size: .init(width: 1, height: bounds.height)
        )
      }

      do {
        horizontalLine1.frame = .init(
          origin: .init(x: 0, y: height),
          size: .init(width: bounds.width, height: 1)
        )

        horizontalLine2.frame = .init(
          origin: .init(x: 0, y: height * 2),
          size: .init(width: bounds.width, height: 1)
        )

      }
    }

  }

  public final class CropInsideOverlayRuleOfThirdsView: CropInsideOverlayBase {

    private let handlesView = CropOverlayHandlesView()
    private let guideView = RuleOfThirdsView()

    private var currentAnimator: UIViewPropertyAnimator?

    public override init() {
      super.init()

      isUserInteractionEnabled = false
      addSubview(handlesView)
      addSubview(guideView)
      AutoLayoutTools.setEdge(handlesView, self)
      AutoLayoutTools.setEdge(guideView, self)

      guideView.alpha = 0
    }

    public override func didBeginAdjustment(kind: CropView.State.AdjustmentKind) {
      currentAnimator?.stopAnimation(true)
      currentAnimator = UIViewPropertyAnimator(duration: 0.6, dampingRatio: 1) { [weak self] in
        self?.guideView.alpha = 1
      }&>.do {
        $0.startAnimation()
      }
    }

    public override func didEndAdjustment(kind: CropView.State.AdjustmentKind) {
      currentAnimator?.stopAnimation(true)
      currentAnimator = UIViewPropertyAnimator(duration: 0.6, dampingRatio: 1) { [weak self] in
        self?.guideView.alpha = 0
      }&>.do {
        $0.startAnimation()
      }
    }
  }
}
