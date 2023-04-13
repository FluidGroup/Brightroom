//
//  UIViewController+Picker.swift
//  Demo
//
//  Created by Muukii on 2021/03/22.
//  Copyright © 2021 muukii. All rights reserved.
//

import UIKit
import Photos
import PhotosUI

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
    let pickerDelegateProxy = PickerDelegateProxy()
    pickerDelegateProxy.onPick = { controller, tasks in
      controller.dismiss(animated: true)
      withExtendedLifetime(pickerDelegateProxy, {})
      Task {
        switch await tasks.first?.result {
        case nil:
          print("No result picking image")
        case .success(let image):
          completion(image)
        case .failure(let error):
          print("Error \(error) picking image")
        }
      }
    }
    var configuration = PHPickerConfiguration()
    configuration.selectionLimit = 1
    configuration.filter = .images
    let controller = PHPickerViewController(configuration: configuration)
    controller.delegate = pickerDelegateProxy
    present(controller, animated: true, completion: nil)
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

private final class PickerDelegateProxy: NSObject, PHPickerViewControllerDelegate {
  private enum Error: Swift.Error {
    case couldNotCoalesceImage
  }
  override init() {
    super.init()
  }

  var onPick: (PHPickerViewController, [Task<UIImage, Swift.Error>]) -> Void = { _,_ in assertionFailure() }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    let type: NSItemProviderReading.Type = UIImage.self
    let tasks = results
      .map { $0.itemProvider }
      .filter { $0.canLoadObject(ofClass: type) }
      .map { provider -> Task<UIImage, Swift.Error> in
          .init {
            try await withCheckedThrowingContinuation { (continuation) in
              provider.loadObject(ofClass: type) { image, error in
                if let error = error {
                  continuation.resume(with: .failure(error))
                } else if let image = image as? UIImage {
                  continuation.resume(with: .success(image))
                } else {
                  continuation.resume(with: .failure(Error.couldNotCoalesceImage))
                }
              }
            }
          }
      }
    onPick(picker, tasks)
  }
}
