//
//  DrawnPathInRect.swift
//  PixelEngine
//
//  Created by muukii on 10/16/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

public struct DrawnPathInRect : GraphicsDrawing, Equatable {

  public let inRect: CGRect
  public let path: DrawnPath

  public init(path: DrawnPath, in rect: CGRect) {
    self.path = path
    self.inRect = rect
  }

  public func draw(in context: CGContext, canvasSize: CGSize) {
    path.draw(in: context, canvasSize: canvasSize)
  }
}
