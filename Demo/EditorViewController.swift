//
//  EditorViewController.swift
//  Demo
//
//  Created by muukii on 10/9/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import UIKit

import PixelEngine
import PixelEditor

final class EditorViewController : UIViewController {

  @IBOutlet weak var imageView: UIImageView!

  override func viewDidLoad() {
    super.viewDidLoad()
  }

  @IBAction func didTapPresentButton() {

    let controller = PixelEditViewController.init(image: UIImage(named: "large")!)

    present(controller, animated: true, completion: nil)
  }

  @IBAction func didTapPushButton(_ sender: Any) {

    let controller = PixelEditViewController.init(image: UIImage(named: "unsplash1")!)
    controller.delegate = self
    
    navigationController?.pushViewController(controller, animated: true)
  }
}

extension EditorViewController : PixelEditViewControllerDelegate {

  func pixelEditViewController(_ controller: PixelEditViewController, didEndEditing image: UIImage) {

    self.navigationController?.popToViewController(self, animated: true)
    self.imageView.image = image
    print(image)
  }

}
