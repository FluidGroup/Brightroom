//
//  SmallUIImageViewController.swift
//  Demo
//
//  Created by muukii on 10/11/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import UIKit

import PixelEngine

final class SmallUIImageViewController : UIViewController {

  @IBOutlet weak var slider: UISlider!
  @IBOutlet weak var imageView: UIImageView!

  let image: CIImage = {
    return ImageTool.createPreviewSizeImage(source: CIImage(image: UIImage(named: "large")!)!, size: CGSize(width: 500, height: 500))!
  }()

  override func viewDidLoad() {
    super.viewDidLoad()

    //    imageView.image = UIImage(ciImage: image)
  }

  @IBAction func didChangeSliderValue(_ sender: Any) {

    let value = slider.value

    let result = SmallUIImageViewController.blur(image: image, radius: Double(value * 50))!

    print(result)
    imageView.image = UIImage(ciImage: result)
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
