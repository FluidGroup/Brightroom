//
//  UIViewController+Picker.swift
//  Demo
//
//  Created by Muukii on 2021/03/22.
//  Copyright © 2021 muukii. All rights reserved.
//

import Foundation
import MosaiqueAssetsPicker

extension UIViewController {

  func __takePhoto(_ completion: @escaping (UIImage) -> Void) {

    let controller = UIImagePickerController()
    controller.sourceType = .camera
    controller.cameraCaptureMode = .photo

    let delegate = _UIImagePickerControllerDelegate()

    controller.delegate = delegate

    delegate.onCancelled = {

    }

    delegate.onCaptured = { image in
      withExtendedLifetime(delegate, {})
      completion(image)
    }

    present(controller, animated: true, completion: nil)

  }

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

private final class _UIImagePickerControllerDelegate: NSObject, UINavigationControllerDelegate,
  UIImagePickerControllerDelegate
{

  var onCaptured: (UIImage) -> Void = { _ in }
  var onCancelled: () -> Void = {}

  func imagePickerController(
    _ picker: UIImagePickerController,
    didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
  ) {

    guard let image = info[.originalImage] as? UIImage else { return }

    picker.dismiss(animated: true, completion: nil)

    onCaptured(image)

  }

  func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {

    picker.dismiss(animated: true, completion: nil)

    onCancelled()
  }
}

private final class MosaiqueAssetsPickerDelegateProxy: MosaiqueAssetPickerDelegate {

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
