//
//  DemoCropViewController.swift
//  Demo
//
//  Created by Muukii on 2021/02/27.
//  Copyright © 2021 muukii. All rights reserved.
//

import Foundation
import UIKit

import PixelEditor

final class DemoCropViewController: UIViewController {
  
  @IBOutlet weak var previewImageView: UIImageView!
  
  @IBAction func onTapHorizontal(_ sender: Any) {
    
    let stack = Mocks.makeEditingStack(image: Mocks.imageHorizontal())
    stack.start()
    let controller = CropViewController(editingStack: stack)
    
    controller.handlers.didFinish = { [weak self, weak controller] in
      guard let self = self else { return }
      controller?.dismiss(animated: true, completion: nil)
      self.previewImageView.image = stack.makeRenderer().render()
    }
    
    present(controller, animated: true, completion: nil)
  }
  
  @IBAction func onTapVertical(_ sender: Any) {
    
    let stack = Mocks.makeEditingStack(image: Mocks.imageVertical())
    stack.start()
    let controller = CropViewController(editingStack: stack)
    
    controller.handlers.didFinish = { [weak self, weak controller] in
      guard let self = self else { return }
      controller?.dismiss(animated: true, completion: nil)
      stack.makeRenderer().asyncRender { (image) in
        self.previewImageView.image = image
      }
    }
    
    present(controller, animated: true, completion: nil)
  }
  
  @IBAction func onTapSquare(_ sender: Any) {
    
    let stack = Mocks.makeEditingStack(image: Mocks.imageSquare())
    stack.start()
    let controller = CropViewController(editingStack: stack)
    
    controller.handlers.didFinish = { [weak self, weak controller] in
      guard let self = self else { return }
      controller?.dismiss(animated: true, completion: nil)
      stack.makeRenderer().asyncRender { (image) in
        self.previewImageView.image = image
      }
    }
    
    present(controller, animated: true, completion: nil)
  }
  
  @IBAction func onTapSuperSmall(_ sender: Any) {
    
    let stack = Mocks.makeEditingStack(image: Mocks.imageSuperSmall())
    stack.start()
    let controller = CropViewController(editingStack: stack)
    
    controller.handlers.didFinish = { [weak self, weak controller] in
      guard let self = self else { return }
      controller?.dismiss(animated: true, completion: nil)
      stack.makeRenderer().asyncRender { (image) in
        self.previewImageView.image = image
      }
    }
    
    present(controller, animated: true, completion: nil)
  }
}
