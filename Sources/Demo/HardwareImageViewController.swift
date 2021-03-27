//
// Copyright (c) 2018 Muukii <muukii.app@gmail.com>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import UIKit

import CoreImage
import BrightroomEngine
import PixelEditor

final class HardwareImageViewController : UIViewController {

  @IBOutlet weak var slider: UISlider!
  @IBOutlet weak var imageConatinerView: UIView!

  let imageView: UIView & CIImageDisplaying = {
    #if canImport(MetalKit) && !targetEnvironment(simulator)
    return MetalImageView()
    #else
    return GLImageView()
    #endif
  }()

  let image: CIImage = {
    return CIImage(image: UIImage(named: "large")!)!
      .transformed(by: .init(scaleX: 0.5, y: 0.5))
      .insertingIntermediate(cache: true)
  }()
  
  let filter = CIFilter(
    name: "CIGaussianBlur",
    parameters: [:]
  )
  
  var outputImage: CIImage?

  override func viewDidLoad() {
    super.viewDidLoad()

    imageConatinerView.addSubview(imageView)
    imageView.frame = imageConatinerView.bounds
    imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

    filter?.setValue(image.clamped(to: image.extent), forKey: kCIInputImageKey)
    
    outputImage = filter?.outputImage
//    filter?.setValue(image, forKey: kCIInputImageKey)

  }

  @IBAction func didChangeSliderValue(_ sender: Any) {
    
    let value = slider.value

    #if true
    filter?.setValue(Double(value * 50), forKey: "inputRadius")
//    print(filter?.outputImage, outputImage)
    let result = filter?.outputImage?.cropped(to: image.extent)
    imageView.display(image: result)
    #else
    let result = HardwareImageViewController.makeBlur(image: image, radius: Double(value * 50))!
    imageView.display(image: result)
    #endif
  }

  static func makeBlur(image: CIImage, radius: Double) -> CIImage? {
    

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

