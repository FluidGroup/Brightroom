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
        do {
          guard let image = try await tasks.first?.getImage() else {
            print("No result picking image. User cancelled")
            return
          }
          completion(image)
        } catch {
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

  final class ImageResult {

    private enum Error: Swift.Error {
      case couldNotCoalesceImage
    }

    private let itemProvider: NSItemProvider
    /// Must call getImage first
    var progress: Progress!

    func getImage() async throws -> UIImage {
      try await withCheckedThrowingContinuation { (continuation) in
        self.progress = itemProvider.loadObject(ofClass: UIImage.self) { image, error in
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

    func getPreview() async throws -> UIImage {
      try await withCheckedThrowingContinuation { (continuation) in
        itemProvider.loadPreviewImage(completionHandler: { image, error in
          if let error = error {
            continuation.resume(with: .failure(error))
          } else if let image = image as? UIImage {
            continuation.resume(with: .success(image))
          } else {
            continuation.resume(with: .failure(Error.couldNotCoalesceImage))
          }
        })
      }
    }

    init(_ itemProvider: NSItemProvider) {
      self.itemProvider = itemProvider
    }
  }

  override init() {
    super.init()
  }

  var onPick: (PHPickerViewController, [ImageResult]) -> Void = { _,_ in assertionFailure() }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    let imageResults = results
      .map { $0.itemProvider }
      .filter { $0.canLoadObject(ofClass: UIImage.self) }
      .map { ImageResult($0) }
    onPick(picker, imageResults)
  }
}
