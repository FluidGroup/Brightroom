//
//  EditingCanvasView.CropInsideOverlay.swift
//  BrightroomUI
//
//  Created by Muukii on 2021/03/03.
//  Copyright © 2021 muukii. All rights reserved.
//

import SwiftUI
import UIKit

/// https://havecamerawilltravel.com/lightroom/crop-overlays/
extension EditingCanvasView {
  final class CropOverlayHandlesView: CodeBasedView {

    let edgeShapeLayer = UIView()

    private let cornerTopLeftHorizontalShapeLayer = UIView()
    private let cornerTopLeftVerticalShapeLayer = UIView()

    private let cornerTopRightHorizontalShapeLayer = UIView()
    private let cornerTopRightVerticalShapeLayer = UIView()

    private let cornerBottomLeftHorizontalShapeLayer = UIView()
    private let cornerBottomLeftVerticalShapeLayer = UIView()

    private let cornerBottomRightHorizontalShapeLayer = UIView()
    private let cornerBottomRightVerticalShapeLayer = UIView()

    init() {
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

    override func layoutSubviews() {
      super.layoutSubviews()

      edgeShapeLayer.frame = bounds.insetBy(dx: -1, dy: -1)
      edgeShapeLayer.layer.borderWidth = 1
      edgeShapeLayer.layer.borderColor = UIColor.white.cgColor

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

  class CropInsideOverlayBase: CodeBasedView {

    init() {
      super.init(frame: .zero)
    }

    func didBeginInteraction(_ interaction: CropInteraction) {

    }

    func didEndInteraction(_ interaction: CropInteraction) {

    }

  }

  class SwiftUICropInsideOverlay<Content: View>: CropInsideOverlayBase {

    private let controller: UIHostingController<Container>
    private let proxy: Proxy

    init(@ViewBuilder content: @escaping (CropInteraction?) -> Content) {
      
      self.proxy = .init()
      self.controller = .init(rootView: Container(proxy: proxy, content: content))

      controller.view.backgroundColor = .clear
      controller.view.preservesSuperviewLayoutMargins = false

      super.init()
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

  final class RuleOfThirdsView: CodeBasedView {

    private let verticalLine1 = UIView()
    private let verticalLine2 = UIView()

    private let horizontalLine1 = UIView()
    private let horizontalLine2 = UIView()

    init(lineColor: UIColor = UIColor(white: 1, alpha: 0.3)) {
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

    override func layoutSubviews() {

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

  final class CropInsideOverlayRuleOfThirdsView: CropInsideOverlayBase {

    private let handlesView = CropOverlayHandlesView()
    private let guideView = RuleOfThirdsView()

    private var currentAnimator: UIViewPropertyAnimator?

    override init() {
      super.init()

      isUserInteractionEnabled = false
      addSubview(handlesView)
      addSubview(guideView)
      AutoLayoutTools.setEdge(handlesView, self)
      AutoLayoutTools.setEdge(guideView, self)

      guideView.alpha = 0
    }

    override func didBeginInteraction(_ interaction: CropInteraction) {
      currentAnimator?.stopAnimation(true)
      let animator = UIViewPropertyAnimator(duration: 0.6, dampingRatio: 1) { [weak self] in
        self?.guideView.alpha = 1
      }
      animator.startAnimation()
      currentAnimator = animator
    }

    override func didEndInteraction(_ interaction: CropInteraction) {
      currentAnimator?.stopAnimation(true)
      let animator = UIViewPropertyAnimator(duration: 0.6, dampingRatio: 1) { [weak self] in
        self?.guideView.alpha = 0
      }
      animator.startAnimation()
      currentAnimator = animator
    }
  }
}
