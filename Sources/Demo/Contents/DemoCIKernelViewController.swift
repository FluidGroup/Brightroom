import AsyncDisplayKit
import TextureSwiftSupport
import UIKit

import BrightroomUI
import BrightroomEngine

final class DemoCIKernelViewController: StackScrollNodeViewController {
  
  override init() {
    super.init()
    title = "CIKernel"
  }
  
  private let resultCell = Components.ResultImageCell()
  
  override func viewDidLoad() {
    super.viewDidLoad()
    
    stackScrollNode.append(nodes: [
      
      resultCell,
           
//      Components.makeSelectionCell(title: "ColorLookup", onTap: { [unowned self] in
//       
//        let filter = ColorLookup()
//        filter.inputImage = CIImage(image: Asset.l1000069.image)!
//        let result = UIImage(ciImage: filter.outputImage!)
//        resultCell.image = result
//      }),
           
    ])
  }
}
