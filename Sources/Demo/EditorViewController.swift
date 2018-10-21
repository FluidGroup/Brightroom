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
    
    let picker = UIImagePickerController()
    picker.allowsEditing = false
    picker.delegate = self
    picker.sourceType = .photoLibrary
    
    present(picker, animated: true, completion: nil)
  }
  
  @IBAction func didTapPushKeepingButton(_ sender: Any) {
    
    let controller = PixelEditViewController.init(editingStack: stack)
    controller.delegate = self
    
    navigationController?.pushViewController(controller, animated: true)
    
  }
}

extension EditorViewController : UIImagePickerControllerDelegate, UINavigationControllerDelegate {
  
  func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
    picker.dismiss(animated: true, completion: nil)
  }
  
  func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
    
    let image = info[.originalImage] as! UIImage
    
    picker.dismiss(animated: true, completion: nil)
    
    let controller = PixelEditViewController.init(image: image, colorCubeFilters: ColorCubeStorage.filters)
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
