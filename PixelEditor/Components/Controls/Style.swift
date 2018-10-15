//
//  Style.swift
//  PixelEditor
//
//  Created by muukii on 10/16/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

public struct Style {

  public static let `default` = Style()

  public struct Control {

    public var backgroundColor = UIColor(white: 0.98, alpha: 1)

    public init() {

    }
  }

  public var control = Control()

  public init() {

  }

}
