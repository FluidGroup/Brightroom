import AsyncDisplayKit
import MetalKit
import TextureSwiftSupport
import UIKit

@testable import BrightroomEngine
@testable import BrightroomUI

final class DemoLUTViewController: StackScrollNodeViewController {

  private let resultCell = Components.ResultImageCell()

  override init() {
    super.init()
    title = "Crop"
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    var counter = 0

    stackScrollNode.append(nodes: [
      resultCell,

      Components.makeSelectionCell(
        title: "Import LUT",
        onTap: { [unowned self] in

          __pickPhoto { (image) in

            var errorMessages: [String] = []

            if image.scale != 1 {
              errorMessages.append("image's scale is not 1.")
            }

            if image.size != .init(width: 512, height: 512) {
              errorMessages.append("image size is not square:512. Imported:\(image.size)")
            }

            if errorMessages.isEmpty == false {

              let errorMessage = errorMessages.joined(separator: "\n")

              let controller = UIAlertController(
                title: "Invalid file",
                message: errorMessage,
                preferredStyle: .alert
              )
              controller.addAction(.init(title: "OK", style: .default, handler: nil))
              present(controller, animated: true, completion: nil)

              return
            }

            counter += 1
            let id = "Imported_\(counter)"

            let filter = FilterColorCube(
              name: id,
              identifier: id,
              lutImage: .init(image: image),
              dimension: 64
            )

            ColorCubeStorage.default.filters.insert(filter, at: 0)

            print(image.size)
          }

        }
      ),

      Components.makeSelectionCell(
        title: "Open Image",
        onTap: { [unowned self] in

          __pickPhoto { (image) in
            let stack = EditingStack(imageProvider: .init(image: image))
            _present(stack, square: false, faceDetection: false)
          }

        }
      ),

      Components.makeSelectionCell(
        title: "Take picture",
        onTap: { [unowned self] in

          __takePhoto { (image) in
            let stack = EditingStack(imageProvider: .init(image: image))
            _present(stack, square: false, faceDetection: false)
          }

        }
      ),

    ])
  }

  private func _present(_ editingStack: EditingStack, square: Bool, faceDetection: Bool = false) {
    var options = ClassicImageEditOptions()

    options.isFaceDetectionEnabled = faceDetection
    if square {
      options.croppingAspectRatio = .square
    } else {
      options.croppingAspectRatio = nil
    }

    let controller = ClassicImageEditViewController(editingStack: editingStack, options: options)
    controller.handlers.didEndEditing = { [weak self] controller, stack in
      guard let self = self else { return }
      controller.dismiss(animated: true, completion: nil)

      self.resultCell.image = nil

      try! stack.makeRenderer().render { result in
        switch result {
        case let .success(rendered):
          self.resultCell.image = rendered.uiImage
        case let .failure(error):
          print(error)
        }
      }
    }

    controller.handlers.didCancelEditing = { controller in
      controller.dismiss(animated: true, completion: nil)
    }

    let navigationController = UINavigationController(rootViewController: controller)
    navigationController.modalPresentationStyle = .fullScreen

    present(navigationController, animated: true, completion: nil)
  }

  private func _presentSquare(_ imageProvider: ImageProvider) {
    let stack = EditingStack.init(
      imageProvider: imageProvider
    )

    _present(stack, square: true)
  }

  private func _presentNonSquare(_ imageProvider: ImageProvider) {
    let stack = EditingStack.init(
      imageProvider: imageProvider
    )

    _present(stack, square: false)
  }

}
