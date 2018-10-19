//
//  OvalBrush.swift
//  PixelEngine
//
//  Created by muukii on 10/9/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

public struct OvalBrush : Equatable {

  public static func == (lhs: OvalBrush, rhs: OvalBrush) -> Bool {
    guard lhs.color == rhs.color else { return false }
    guard lhs.width == rhs.width else { return false }
    guard lhs.alpha == rhs.alpha else { return false }
    guard lhs.blendMode == rhs.blendMode else { return false }
    return true
  }

  // MARK: - Properties

  public let color: UIColor
  public let width: CGFloat
  public let alpha: CGFloat
  public let blendMode: CGBlendMode

  // MARK: - Initializers

  public init(
    color: UIColor,
    width: CGFloat,
    alpha: CGFloat = 1,
    blendMode: CGBlendMode = .normal
    ) {

    self.color = color
    self.width = width
    self.alpha = alpha
    self.blendMode = blendMode
  }
}
