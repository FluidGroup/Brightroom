import AsyncDisplayKit
import GlossButtonNode
import TextureSwiftSupport
import UIKit

import BrightroomUI
import BrightroomEngine

final class DemoBuiltInEditorViewController: StackScrollNodeViewController {
  
  override init() {
    super.init()
    title = "Editor"
  }
  
  private let resultCell = Components.ResultImageCell()
  private let stack = EditingStack.init(
    imageProvider: .init(image: Asset.leica.image),
    cropModifier: .init { _, crop, completion in
      var new = crop
      new.updateCropExtent(by: .square)
      completion(new)
    }
  )
  
  override func viewDidLoad() {
    super.viewDidLoad()
    
    stackScrollNode.append(nodes: [
      
      resultCell,
      
      Components.makeSelectionCell(title: "Pick", onTap: { [unowned self] in
        
        __pickPhoto { (image) in
          self._present(.init(image: image))
        }
        
      }),
      
      Components.makeSelectionCell(title: "Example", onTap: { [unowned self] in
        _present(.init(image: Asset.leica.image))
      }),
      
      Components.makeSelectionCell(title: "Example with keeping", onTap: { [unowned self] in
        _present(stack)
      }),
      
      Components.makeSelectionCell(title: "Oriented image", onTap: { [unowned self] in
        _present(try! .init(fileURL: _url(forResource: "IMG_5528", ofType: "HEIC")))
      }),
      
      
    ])
  }
  
  private func _present(_ editingStack: EditingStack) {
           
    let controller = ClassicImageEditViewController(editingStack: editingStack)
    controller.handlers.didEndEditing = { [weak self] controller, stack in
      guard let self = self else { return }
      controller.dismiss(animated: true, completion: nil)
      stack.makeRenderer()?.render { (image) in
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
  
  private func _present(_ imageProvider: ImageProvider) {
        
    let stack = EditingStack.init(
      imageProvider: imageProvider,
      cropModifier: .init { _, crop, completion in
        var new = crop
        new.updateCropExtent(by: .square)
        completion(new)
      }
    )
    
    _present(stack)
  }
}

