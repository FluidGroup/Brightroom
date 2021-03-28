//
//  UIViewController+Picker.swift
//  Demo
//
//  Created by Muukii on 2021/03/22.
//  Copyright © 2021 muukii. All rights reserved.
//

import MosaiqueAssetsPicker
import Foundation

extension UIViewController {
  
  func __pickPhoto(_ completion: @escaping (UIImage) -> Void) {
    
    let pickerDelegateProxy = MosaiqueAssetsPickerDelegateProxy()
    
    var configuration = MosaiqueAssetPickerConfiguration()
    
    configuration.selectionMode = .single
    configuration.numberOfItemsPerRow = 3
    
    let photoPicker = MosaiqueAssetPickerPresenter.controller(
      delegate: pickerDelegateProxy,
      configuration: configuration
    )
    
    pickerDelegateProxy.onPicked = { controller, images in
      controller.dismiss(animated: true, completion: nil)
      withExtendedLifetime(pickerDelegateProxy, {})
      completion(images.first!)
    }
    pickerDelegateProxy.onCancelled = { controller in
      controller.dismiss(animated: true, completion: nil)
    }
        
    present(photoPicker, animated: true, completion: nil)
  }
}


fileprivate final class MosaiqueAssetsPickerDelegateProxy: MosaiqueAssetPickerDelegate {
  
  var onPicked: (UIViewController, [UIImage]) -> Void = { _, _ in }
  var onCancelled: (UIViewController) -> Void = { _ in }
  
  init() {
    
  }
  
  func photoPicker(_ controller: UIViewController, didPickImages images: [UIImage]) {
    onPicked(controller, images)
  }
  
  func photoPicker(_ controller: UIViewController, didPickAssets assets: [AssetFuture]) {
  }
  
  func photoPickerDidCancel(_ controller: UIViewController) {
    onCancelled(controller)
  }
  
}



