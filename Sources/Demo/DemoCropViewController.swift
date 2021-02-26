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
  
  @IBAction func onTap(_ sender: Any) {
    
    let stack = Mocks.makeEditingStack()
    stack.start()
    let controller = CropViewController(editingStack: stack)
    
    present(controller, animated: true, completion: nil)
  }
}
