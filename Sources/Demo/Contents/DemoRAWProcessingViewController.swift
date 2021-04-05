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
        title: "Open Crop",
        onTap: { [unowned self] in

          let url = _url(forResource: "AppleRAW_1", ofType: "DNG")

          _presentCropViewConroller(.init(imageProvider: .init(rawDataURL: url)))
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

  private func _presentCropViewConroller(_ editingStack: EditingStack) {
    let crop = PhotosCropViewController(editingStack: editingStack)
    _presentCropViewConroller(crop)
  }

  private func _presentCropViewConroller(_ crop: PhotosCropViewController) {
    crop.modalPresentationStyle = .fullScreen
    crop.handlers.didCancel = { controller in
      controller.dismiss(animated: true, completion: nil)
    }
    crop.handlers.didFinish = { [weak self] controller in
      controller.dismiss(animated: true, completion: nil)
      self?.resultCell.image = nil

      try! controller.editingStack.makeRenderer()
        .render { (result) in
          switch result {
          case .success(let rendered):
            self?.resultCell.image = rendered.uiImage
          case .failure(let error):
            print(error)
          }
        }
    }

    present(crop, animated: true, completion: nil)
  }

}
