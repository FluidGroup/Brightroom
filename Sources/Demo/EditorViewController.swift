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

import PixelEngine
import PixelEditor

final class EditorViewController : UIViewController {

  @IBOutlet weak var imageView: UIImageView!
  
  private lazy var stack = SquareEditingStack.init(
    source: ImageSource(source: UIImage(named: "large")!),
    previewSize: CGSize(width: 300, height: 300),
    colorCubeStorage: ColorCubeStorage.default
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
    
    let controller = PixelEditViewController.init(
      image: image
    )
    
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
