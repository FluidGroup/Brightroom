import AsyncDisplayKit
import MetalKit
import TextureSwiftSupport
import UIKit

@testable import BrightroomEngine
@testable import BrightroomUI

final class DemoRAWProcessingViewController: StackScrollNodeViewController {

  private let resultCell = Components.ResultImageCell()

  override init() {
    super.init()
    title = "RAW"
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    stackScrollNode.append(nodes: [
      resultCell,

      Components.makeSelectionCell(
        title: "Load RAW",
        onTap: { [unowned self] in

          let url = _url(forResource: "AppleRAW_1", ofType: "DNG")
          let data = try! Data.init(contentsOf: url)

          let filter = CIFilter(imageData: data, options: [:])!
          let image = filter.outputImage!
          print(image)

          let ciContext = CIContext()

          let cgImage = ciContext.createCGImage(image, from: image.extent)!

          resultCell.image = UIImage(cgImage: cgImage)
        }
      ),

      Components.makeSelectionCell(
        title: "Write RAW",
        onTap: { 

          let url = _url(forResource: "AppleRAW_1", ofType: "DNG")

          let filter = CIFilter(imageURL: url, options: [:])!
          let image = filter.outputImage!

          let ciContext = CIContext()

          let target = URL(fileURLWithPath: NSTemporaryDirectory() + "/raw_image.jpeg")
          try! ciContext.writeJPEGRepresentation(of: image, to: target, colorSpace: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(), options: [:])

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
