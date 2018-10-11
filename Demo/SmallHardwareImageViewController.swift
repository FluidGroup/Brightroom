//
//  SmallHardwareImageViewController.swift
//  Demo
//
//  Created by muukii on 10/11/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import UIKit

import PixelEngine

final class SmallHardwareImageViewController : UIViewController {

  @IBOutlet weak var slider: UISlider!
  @IBOutlet weak var imageConatinerView: UIView!

  let imageView: UIView & HardwareImageViewType = {
    #if canImport(MetalKit) && !targetEnvironment(simulator)
    return MetalImageView()
    #else
    return GLImageView()
    #endif
  }()

  let image: CIImage = {
    return ImageTool.resize(to: CGSize(width: 500, height: 500), from: CIImage(image: UIImage(named: "large")!)!)!
  }()

  override func viewDidLoad() {
    super.viewDidLoad()

    imageConatinerView.addSubview(imageView)
    imageView.frame = imageConatinerView.bounds
    imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

  }

  @IBAction func didChangeSliderValue(_ sender: Any) {

    let value = slider.value

    let result = SmallHardwareImageViewController.blur(image: image, radius: Double(value * 50))!

    imageView.image = result
  }

  static func blur(image: CIImage, radius: Double) -> CIImage? {

    let outputImage = image
      .clamped(to: image.extent)
      .applyingFilter(
        "CIGaussianBlur",
        parameters: [
          "inputRadius" : radius
        ])
      .cropped(to: image.extent)

    return outputImage
  }
}



