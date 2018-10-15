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

    let engine = ImageRenderer(source: ImageSource.init(source: image))

    let path = DrawnPath(
      brush: .init(color: .red, width: 30),
      path: .init(rect: CGRect.init(x: 0, y: 0, width: 50, height: 50))
    )

    engine.edit.croppingRect = CGRect(x: 0, y: 0, width: 400, height: 400)
    engine.edit.drawer = [
      path,
      BlurredMask(paths: []),
    ]

    let result = engine.render()

    imageView.image = result
  }
}
