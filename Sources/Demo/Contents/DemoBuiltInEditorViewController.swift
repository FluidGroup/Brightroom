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
      
      Components.makeSelectionCell(title: "DisplayP3", onTap: { [unowned self] in
        _present(.init(image: Asset.instaLogo.image))
      }),
      
      Components.makeSelectionCell(title: "Example with keeping", onTap: { [unowned self] in
        _present(stack)
      }),
      
      Components.makeSelectionCell(title: "Oriented image", onTap: { [unowned self] in
        _present(try! .init(fileURL: _url(forResource: "IMG_5528", ofType: "HEIC")))
      }),
      
      Components.makeSelectionCell(title: "Remote image", onTap: { [unowned self] in
        
        let stack = EditingStack(
          imageProvider: .init(
            editableRemoteURL: URL(string: "https://images.unsplash.com/photo-1597522781074-9a05ab90638e?ixlib=rb-1.2.1&ixid=MXwxMjA3fDB8MHxwaG90by1wYWdlfHx8fGVufDB8fHw%3D")!
          )
        )
        
        _present(stack)
      }),
      
      
    ])
  }
  
  private func _present(_ editingStack: EditingStack) {
           
    let controller = ClassicImageEditViewController(editingStack: editingStack)
    controller.handlers.didEndEditing = { [weak self] controller, stack in
      guard let self = self else { return }
      controller.dismiss(animated: true, completion: nil)
      
      self.resultCell.image = nil

      try! stack.makeRenderer().render { (result) in
        switch result {
        case .success(let rendered):
          self.resultCell.image = rendered.uiImageDisplayP3
        case .failure(let error):
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

