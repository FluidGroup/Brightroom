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
  
  private lazy var stack = SquareEditingStack.init(
    source: ImageSource(source: UIImage(named: "large")!),
    previewSize: CGSize(width: 30, height: 30),
    colorCubeFilters: ColorCubeStorage.filters
  )

  override func viewDidLoad() {
    super.viewDidLoad()
  }

  @IBAction func didTapPresentButton() {

    let controller = PixelEditViewController.init(image: UIImage(named: "large")!)
    
    let nav = UINavigationController(rootViewController: controller)

    present(nav, animated: true, completion: nil)
  }

  @IBAction func didTapPushButton(_ sender: Any) {

    let controller = PixelEditViewController.init(image: UIImage(named: "vertical")!)
    controller.delegate = self
    
    navigationController?.pushViewController(controller, animated: true)
  }
  
  @IBAction func didTapPushKeepingButton(_ sender: Any) {
    
    let controller = PixelEditViewController.init(editingStack: stack)
    controller.delegate = self
    
    navigationController?.pushViewController(controller, animated: true)
    
  }
}

extension EditorViewController : PixelEditViewControllerDelegate {

  func pixelEditViewController(_ controller: PixelEditViewController, didEndEditing image: UIImage) {

    self.navigationController?.popToViewController(self, animated: true)
    self.imageView.image = image
  }
  
  func pixelEditViewControllerDidCancelEditing(in controller: PixelEditViewController) {
    self.navigationController?.popToViewController(self, animated: true)
  }
  
}
