//
//  ViewController.swift
//  Demo
//
//  Created by muukii on 10/8/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import UIKit

import PixelEngine

class ViewController: UIViewController {

  @IBOutlet weak var imageView: UIImageView!

  override func viewDidLoad() {
    super.viewDidLoad()
  }

  @IBAction func didTapButton(_ sender: Any) {

    let image = UIImage(named: "small")!

    let engine = ImageEngine(fullResolutionOriginalImage: image)

    engine.croppingRect = CGRect(x: 0, y: 0, width: 300, height: 300)

    let result = engine.render()

    imageView.image = result
  }
}
