
import AsyncDisplayKit
import GlossButtonNode
import TextureSwiftSupport
import UIKit

import BrightroomUI
import BrightroomEngine

final class DemoMaskingViewController: StackScrollNodeViewController {
  
  override init() {
    super.init()
    title = "Masking"
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
      
      Components.makeSelectionCell(title: "Remote image", onTap: { [unowned self] in
        
        let stack = EditingStack(
          imageProvider: .init(
            editableRemoteURL: URL(string: "https://images.unsplash.com/photo-1604456930969-37f67bcd6e1e?ixid=MXwxMjA3fDB8MHxwaG90by1wYWdlfHx8fGVufDB8fHw%3D&ixlib=rb-1.2.1")!
          )
        )
        
        _present(stack)
      }),
            
    ])
  }
  
  private func _present(_ editingStack: EditingStack) {
    
    let controller = MaskingViewWrapperViewController(editingStack: editingStack)
    
    controller.handlers.didFinish = { [unowned self] in
      self.navigationController?.popViewController(animated: true)
      self.resultCell.image = nil

      try! editingStack.makeRenderer().render { (result) in
        switch result {
        case .success(let rendered):
          self.resultCell.image = rendered.uiImageDisplayP3
        case .failure(let error):
          print(error)
        }
      }
    }
    
    self.navigationController?.pushViewController(controller, animated: true)
  }
  
  private func _present(_ imageProvider: ImageProvider) {
    
    let stack = EditingStack.init(
      imageProvider: imageProvider
    )
    
    _present(stack)
  }
}

import TinyConstraints

private final class MaskingViewWrapperViewController: UIViewController {
  
  struct Handlers {
    var didFinish: () -> Void = {}
  }
  
  var handlers = Handlers()
  private let maskingView: BlurryMaskingView
    
  init(editingStack: EditingStack) {
    
    self.maskingView = BlurryMaskingView(editingStack: editingStack)
    super.init(nibName: nil, bundle: nil)
    
    navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(onTapDoneButton))
    
  }
  
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  override func viewDidLoad() {
    super.viewDidLoad()
    
    view.backgroundColor = .white
    
    view.addSubview(maskingView)
    maskingView.edges(to: view.safeAreaLayoutGuide, insets: .init(top: 20, left: 20, bottom: 20, right: 20))
    
  }
  
  @objc private func onTapDoneButton() {
    handlers.didFinish()
  }
  
}
