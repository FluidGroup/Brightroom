//
//  RealtimeFilterViewController.swift
//  Demo
//
//  Created by muukii on 10/9/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import UIKit

final class UIImageViewViewController : UIViewController {

  @IBOutlet weak var slider: UISlider!
  @IBOutlet weak var imageView: UIImageView!

  let image: CIImage = {

    return CIImage(image: UIImage(named: "large")!)!

  }()

  override func viewDidLoad() {
    super.viewDidLoad()

//    imageView.image = UIImage(ciImage: image)
  }

  @IBAction func didChangeSliderValue(_ sender: Any) {

    let value = slider.value

    let result = RealtimeFilterViewController.blur(image: image.transformed(by: .init(scaleX: 0.3, y: 0.3)), radius: Double(value * 50))!

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
