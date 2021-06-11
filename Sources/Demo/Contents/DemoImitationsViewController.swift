import AsyncDisplayKit
import BrightroomEngine
import BrightroomUI
import TextureSwiftSupport
import TinyConstraints
import UIKit

final class DemoImitationsViewController: StackScrollNodeViewController {

  override init() {
    super.init()
    title = "Imitations"
  }

  private let stack = EditingStack.init(
    imageProvider: try! .init(image: Asset.leica.image), // Handle errors if you can't be sure of the image pixel format.
    cropModifier: .init { _, crop, completion in
      var new = crop
      new.updateCropExtent(toFitAspectRatio: .square)
      completion(new)
    }
  )

  override func viewDidLoad() {
    super.viewDidLoad()

    stackScrollNode.append(nodes: [

      Components.makeSelectionCell(
        title: "Tinder",
        onTap: { [unowned self] in

          let controller = ImitationTinderViewController()

          navigationController?.pushViewController(controller, animated: true)
        })

    ])
  }

}
