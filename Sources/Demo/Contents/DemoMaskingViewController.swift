
import AsyncDisplayKit
import GlossButtonNode
import TextureSwiftSupport
import UIKit

import PixelEditor
import PixelEngine

final class DemoMaskingViewController: StackScrollNodeViewController {
  
  override init() {
    super.init()
    title = "Editor"
  }
  
  private let resultCell = Components.ResultImageCell()
  private let stack = EditingStack.init(imageProvider: .init(image: Asset.leica.image), cropModifier: .init { _, crop in
    crop.updateCropExtent(by: .square)
  })
  
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
    
    let controller = MaskingViewWrapperViewController(editingStack: editingStack)
    
    self.navigationController?.pushViewController(controller, animated: true)
  }
  
  private func _present(_ imageProvider: ImageProvider) {
    
    let stack = EditingStack.init(
      imageProvider: imageProvider,
      previewMaxPixelSize: 400 * 2
    )
    
    _present(stack)
  }
}

import TinyConstraints

private final class MaskingViewWrapperViewController: UIViewController {
  
  private let maskingView: BlurryMaskingView
    
  init(editingStack: EditingStack) {
    
    self.maskingView = BlurryMaskingView(editingStack: editingStack)
    super.init(nibName: nil, bundle: nil)
    
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
  
}
