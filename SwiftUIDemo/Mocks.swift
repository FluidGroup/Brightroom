//
//  Mocks.swift
//  Demo
//
//  Created by Muukii on 2021/02/27.
//  Copyright © 2021 muukii. All rights reserved.
//

import UIKit
import PixelEditor
import PixelEngine

enum Mocks {
  
  static func imageVertical() -> UIImage {
    UIImage(named: "vertical-rect")!
  }
  
  static func imageHorizontal() -> UIImage {
    UIImage(named: "horizontal-rect")!
  }
  
  static func imageSquare() -> UIImage {
    UIImage(named: "square-rect")!
  }
  
  static func imageSuperSmall() -> UIImage {
    UIImage(named: "super-small")!
  }
  
  static func makeEditingStack(image: UIImage) -> EditingStack {
    .init(
      imageProvider: .init(image: image),
      previewMaxPixelSize: .init(width: 600, height: 600)
    )
  }
    
  static func makeEditingStack(fileURL: URL) -> EditingStack {
    .init(
      imageProvider: try! .init(fileURL: fileURL),
      previewMaxPixelSize: .init(width: 600, height: 600)
    )
  }
  
}
