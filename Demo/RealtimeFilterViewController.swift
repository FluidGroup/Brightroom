//
//  RealtimeFilterViewController.swift
//  Demo
//
//  Created by muukii on 10/9/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import UIKit

import PixelEngine

final class RealtimeFilterViewController : UIViewController {

  let imageView: HardwareImageViewType = {
    #if canImport(MetalKit) && !targetEnvironment(simulator)
    return MetalImageView()
    #else
    return GLImageView()
    #endif
  }()

  
}
