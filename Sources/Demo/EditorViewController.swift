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

let pixelCustomActionTapButtonKey = "pixelCustomActionTapButtonKey"

final class EditorViewController : UIViewController {

  @IBOutlet weak var imageView: UIImageView!
  
  private lazy var stack = SquareEditingStack.init(
    source: StaticImageSource(source: UIImage(named: "large")!),
    previewSize: CGSize(width: 300, height: 300),
    colorCubeStorage: ColorCubeStorage.default
  )

  override func viewDidLoad() {
    super.viewDidLoad()
  }

  @IBAction func didTapPresentButton() {

    let controller = PixelEditViewController.init(image: UIImage(named: "large")!)
    controller.delegate = self
    
    let nav = UINavigationController(rootViewController: controller)

    present(nav, animated: true, completion: nil)
  }
  
  @IBAction func didTapShowCustomRootView(_ sender: Any) {
    let image = UIImage(named: "large")!
    
    var options = Options.default
    options.classes.control.rootControl = CertificateSubmissionlRootControl.self
    options.classes.control.customActions = [pixelCustomActionTapButtonKey: { print("Do something!!")}]

    let editingStack = SquareEditingStack(source: StaticImageSource(source: image), previewSize:.init(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.width))
    let controller = PixelEditViewController(editingStack: editingStack, options: options)
    controller.delegate = self
    
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

final class CertificateSubmissionlRootControl: RootControlBase {
    public let colorCubeControl: ColorCubeControlBase

    public lazy var editView = context.options.classes.control.editMenuControl.init(context: context)
    public lazy var helpButton = UIButton(type: .system)
  
    // MARK: - Initializers

    public required init(context: PixelEditContext, colorCubeControl: ColorCubeControlBase) {
        self.colorCubeControl = colorCubeControl
      
        super.init(context: context, colorCubeControl: colorCubeControl)

        self.helpButton.setTitle("Help", for: .normal)
        self.helpButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        self.helpButton.addTarget(self, action: #selector(onTap(gestureRecognizer:)), for: .touchUpInside)
        
        // Same style as the editor style component
        backgroundColor = Style.default.control.backgroundColor
    }
  
    @objc func onTap(gestureRecognizer: UITapGestureRecognizer) {
        if let actionOnTap = context.options.classes.control.customActions[pixelCustomActionTapButtonKey] {
          actionOnTap()
        }
    }

    // MARK: - Functions

    override func didMoveToSuperview() {
        super.didMoveToSuperview()

        let stackView = UIStackView(arrangedSubviews: [editView, helpButton])
        stackView.axis = .vertical
        stackView.distribution = .fillEqually
        
      if superview != nil {
        addSubview(stackView)

        stackView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: stackView.superview!.topAnchor),
            stackView.leftAnchor.constraint(equalTo: stackView.superview!.leftAnchor),
            stackView.rightAnchor.constraint(equalTo: stackView.superview!.rightAnchor),
            stackView.bottomAnchor.constraint(equalTo: stackView.superview!.bottomAnchor)
        ])
        }
    }
}

extension EditorViewController : PixelEditViewControllerDelegate {
  
  func pixelEditViewController(_ controller: PixelEditViewController, didEndEditing editingStack: EditingStack) {
    let image = editingStack.makeRenderer().render(resolution: .full)
    self.imageView.image = image
    
    if controller.presentingViewController != nil {
      self.navigationController?.dismiss(animated: true, completion: nil)
    } else {
      self.navigationController?.popToViewController(self, animated: true)
    }
  }
  
  func pixelEditViewControllerDidCancelEditing(in controller: PixelEditViewController) {
    if controller.presentingViewController != nil {
      self.navigationController?.dismiss(animated: true, completion: nil)
    } else {
      self.navigationController?.popToViewController(self, animated: true)
    }
  }
}
