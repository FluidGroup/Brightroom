import AsyncDisplayKit
import TextureSwiftSupport
import UIKit

class StackScrollNodeViewController: DisplayNodeViewController {
  
  let stackScrollNode = StackScrollNode()
  
  override init() {
    super.init()
//    stackScrollNode.scrollView.delaysContentTouches = false
  }
    
  override func viewDidLoad() {
    super.viewDidLoad()
    
    if #available(iOS 13.0, *) {
      view.backgroundColor = .systemBackground
    } else {
      view.backgroundColor = .white
    }
      
  }
  
  override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
    LayoutSpec {
      stackScrollNode
    }
  }
  
}
