import CoreImage
import BrightroomEngine
import IOSurface
import MetalKit
import os
import simd
import SwiftUI
import UIKit

final class _EditingCanvasDrawingGestureRecognizer: UIGestureRecognizer {

  var onBegin: ((CGPoint) -> Void)?
  var onMove: (([CGPoint]) -> Void)?
  var onEnd: ((CGPoint) -> Void)?
  var onCancel: (() -> Void)?

  private let directTouchDrawingThreshold: CGFloat = 8
  private weak var activeTouch: UITouch?
  private var activeTouchType: UITouch.TouchType?
  private var initialPoint: CGPoint?
  private var didBeginDrawing = false

  override init(target: Any?, action: Selector?) {
    super.init(target: target, action: action)

    cancelsTouchesInView = false
    delaysTouchesBegan = false
    delaysTouchesEnded = false
    allowedTouchTypes = [
      NSNumber(value: UITouch.TouchType.direct.rawValue),
      NSNumber(value: UITouch.TouchType.pencil.rawValue),
    ]
  }

  override func reset() {
    super.reset()
    activeTouch = nil
    activeTouchType = nil
    initialPoint = nil
    didBeginDrawing = false
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    guard activeTouch == nil else {
      finishAsViewportGesture()
      return
    }

    guard
      event.allTouches?.count == 1,
      touches.count == 1,
      let touch = touches.first
    else {
      state = .failed
      return
    }

    activeTouch = touch
    activeTouchType = touch.type
    initialPoint = touch.location(in: view)
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
    guard
      event.allTouches?.count == 1,
      let activeTouch,
      touches.contains(where: { $0 === activeTouch })
    else {
      finishAsViewportGesture()
      return
    }

    let currentPoint = activeTouch.location(in: view)
    guard didBeginDrawing || shouldBeginDrawing(at: currentPoint) else {
      return
    }

    beginDrawingIfNeeded(at: currentPoint)
    let coalescedTouches = event.coalescedTouches(for: activeTouch) ?? [activeTouch]
    let points = coalescedTouches.map { $0.location(in: view) }
    onMove?(points)
    if state == .began {
      return
    }
    state = .changed
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    guard
      let activeTouch,
      touches.contains(where: { $0 === activeTouch })
    else {
      return
    }

    beginDrawingIfNeeded(at: activeTouch.location(in: view))
    onEnd?(activeTouch.location(in: view))
    state = .ended
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
    finishAsViewportGesture()
  }

  private func shouldBeginDrawing(at point: CGPoint) -> Bool {
    guard activeTouchType != .pencil, let initialPoint else {
      return true
    }

    return initialPoint.distance(to: point) >= directTouchDrawingThreshold
  }

  private func beginDrawingIfNeeded(at point: CGPoint) {
    guard didBeginDrawing == false else {
      return
    }

    didBeginDrawing = true
    state = .began
    onBegin?(initialPoint ?? point)
  }

  private func finishAsViewportGesture() {
    guard didBeginDrawing else {
      state = .failed
      return
    }

    onCancel?()
    state = .cancelled
  }
}
