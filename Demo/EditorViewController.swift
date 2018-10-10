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

  override func viewDidLoad() {
    super.viewDidLoad()
  }

  @IBAction func didTapPresentButton() {

    let controller = PixelEditViewController.init(image: UIImage(named: "large")!)

    present(controller, animated: true, completion: nil)
  }

  @IBAction func didTapPushButton(_ sender: Any) {

    let controller = PixelEditViewController.init(image: UIImage(named: "large")!)

    navigationController?.pushViewController(controller, animated: true)
  }
}

