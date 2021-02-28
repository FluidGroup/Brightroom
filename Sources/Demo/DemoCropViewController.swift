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
  
  @IBAction func onTapHorizontal(_ sender: Any) {
    
    let stack = Mocks.makeEditingStack(image: Mocks.imageHorizontal())
    stack.start()
    let controller = CropViewController(editingStack: stack)
    
    present(controller, animated: true, completion: nil)
  }
  
  @IBAction func onTapVertical(_ sender: Any) {
    
    let stack = Mocks.makeEditingStack(image: Mocks.imageVertical())
    stack.start()
    let controller = CropViewController(editingStack: stack)
    
    present(controller, animated: true, completion: nil)
  }
  
  @IBAction func onTapSquare(_ sender: Any) {
    
    let stack = Mocks.makeEditingStack(image: Mocks.imageSquare())
    stack.start()
    let controller = CropViewController(editingStack: stack)
    
    present(controller, animated: true, completion: nil)
  }
  
  @IBAction func onTapSuperSmall(_ sender: Any) {
    
    let stack = Mocks.makeEditingStack(image: Mocks.imageSuperSmall())
    stack.start()
    let controller = CropViewController(editingStack: stack)
    
    present(controller, animated: true, completion: nil)
  }
}
