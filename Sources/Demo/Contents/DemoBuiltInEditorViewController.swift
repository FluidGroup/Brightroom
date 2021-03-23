import AsyncDisplayKit
import GlossButtonNode
import TextureSwiftSupport
import UIKit

import PixelEditor
import PixelEngine

final class DemoBuiltInEditorViewController: StackScrollNodeViewController {
  
  override init() {
    super.init()
    title = "Editor"
  }
  
  private let resultCell = Components.ResultImageCell()
  
  override func viewDidLoad() {
    super.viewDidLoad()
    
    stackScrollNode.append(nodes: [
      
      resultCell,
      
      Components.makeSelectionCell(title: "Example", onTap: { [unowned self] in
        _present(.init(image: Asset.l1000069.image))
      }),
      
      Components.makeSelectionCell(title: "Pick", onTap: { [unowned self] in
        
        __pickPhoto { (image) in
          self._present(.init(image: image))
        }
        
      }),
      
    ])
  }
  
  private func _present(_ imageProvider: ImageProvider) {
        
    let stack = EditingStack.init(
      imageProvider: imageProvider,
      previewMaxPixelSize: 400 * 2,
      cropModifier: .init { _, crop in
        crop.updateCropExtent(by: .square)
      }
    )
    
    let controller = PixelEditViewController(editingStack: stack)
    controller.handlers.didEndEditing = { [weak self] controller, stack in
      guard let self = self else { return }
      controller.dismiss(animated: true, completion: nil)
      stack.makeRenderer().render { (image) in
        self.resultCell.image = image
      }
    }
    
    controller.handlers.didCancelEditing = { controller in
      controller.dismiss(animated: true, completion: nil)
    }
    
    let navigationController = UINavigationController(rootViewController: controller)
    navigationController.modalPresentationStyle = .fullScreen
    
    present(navigationController, animated: true, completion: nil)
  }
}

